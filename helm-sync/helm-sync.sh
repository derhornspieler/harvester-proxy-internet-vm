#!/usr/bin/env bash
# =============================================================================
# helm-sync.sh — HTTP sidecar that syncs HTTP Helm charts to Harbor as OCI
# =============================================================================
# Listens on port 8888 for mirrored requests from nginx. When a .tgz chart
# download is detected, checks if the chart+version exists in Harbor. If not,
# pulls from upstream and pushes to Harbor as an OCI artifact.
#
# OCI-native charts (ghcr.io, docker.io, etc.) are handled by Harbor's built-in
# proxy-cache feature and do not need this sidecar.
#
# Endpoints:
#   GET /sync          — called by nginx mirror on each chart request
#   GET /sync-all      — trigger sync of all HTTP charts from manifest
#   GET /healthz       — health check
# =============================================================================

set -euo pipefail

MANIFEST="/opt/helm-sync/charts.manifest"
LISTEN_PORT="${HELM_SYNC_PORT:-8888}"
HARBOR_HOST="${HARBOR_HOST:?HARBOR_HOST must be set}"
HARBOR_USER="${HARBOR_USER:?HARBOR_USER must be set}"
HARBOR_PASS="${HARBOR_PASS:?HARBOR_PASS must be set}"
LOCKDIR="/tmp/helm-sync-locks"
LOGFILE="/var/log/helm-sync/sync.log"

mkdir -p "$LOCKDIR" "$(dirname "$LOGFILE")"

_log() { echo "[$(date -Iseconds)] $*" >> "$LOGFILE"; }
log_info()  { _log "[INFO]  $*"; }
log_ok()    { _log "[OK]    $*"; }
log_warn()  { _log "[WARN]  $*"; }
log_error() { _log "[ERROR] $*"; }

# ─── Harbor Helpers ──────────────────────────────────────────────────────────

harbor_create_project() {
    local project="$1"
    local status
    status=$(curl -sk -o /dev/null -w "%{http_code}" \
        -X POST "https://${HARBOR_HOST}/api/v2.0/projects" \
        -H "Content-Type: application/json" \
        -u "${HARBOR_USER}:${HARBOR_PASS}" \
        -d "{\"project_name\": \"${project}\", \"public\": true}" 2>/dev/null || echo "000")
    case "$status" in
        201) log_ok "Created Harbor project: ${project}" ;;
        409) ;; # already exists, silent
        *)   log_warn "Harbor project creation returned HTTP ${status} for ${project}" ;;
    esac
}

harbor_artifact_exists() {
    local project="$1" chart="$2" version="$3"
    local response http_code body
    response=$(curl -sk -w "\n%{http_code}" \
        -u "${HARBOR_USER}:${HARBOR_PASS}" \
        "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories/${chart}/artifacts?q=tags%3D${version}&page_size=1" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    [[ "$http_code" == "200" ]] && echo "$body" | grep -q '"digest"'
}

# ─── Chart Sync Logic ────────────────────────────────────────────────────────

sync_chart() {
    local source="$1" version="$2" harbor_project="$3" chart_name="$4"
    local lockfile="${LOCKDIR}/${harbor_project}_${chart_name}_${version}.lock"

    if [[ -f "$lockfile" ]]; then
        return 0
    fi
    touch "$lockfile"

    if harbor_artifact_exists "$harbor_project" "$chart_name" "$version"; then
        log_ok "Already in Harbor: ${harbor_project}/${chart_name}:${version}"
        rm -f "$lockfile"
        return 0
    fi

    log_info "Syncing ${chart_name} ${version} -> oci://${HARBOR_HOST}/${harbor_project}"

    harbor_create_project "$harbor_project"

    local tmpdir repo_alias
    tmpdir=$(mktemp -d)
    repo_alias=$(echo "$harbor_project" | tr '.' '-' | tr '/' '-')
    helm repo add "$repo_alias" "$source" >/dev/null 2>&1 || true
    helm repo update "$repo_alias" >/dev/null 2>&1 || true

    local pull_ok=false
    if [[ "$version" == "latest" ]]; then
        helm pull "${repo_alias}/${chart_name}" -d "$tmpdir" >/dev/null 2>&1 && pull_ok=true
    else
        helm pull "${repo_alias}/${chart_name}" --version "$version" -d "$tmpdir" >/dev/null 2>&1 && pull_ok=true
    fi

    if ! $pull_ok; then
        log_error "Failed to pull ${chart_name} ${version} from ${source}"
        rm -rf "$tmpdir" "$lockfile"
        return 1
    fi

    local tarball
    tarball=$(find "$tmpdir" -name "${chart_name}-*.tgz" 2>/dev/null | head -1)
    if [[ -z "$tarball" ]]; then
        log_error "No tarball found for ${chart_name}"
        rm -rf "$tmpdir" "$lockfile"
        return 1
    fi

    if helm push "$tarball" "oci://${HARBOR_HOST}/${harbor_project}" >/dev/null 2>&1; then
        log_ok "Pushed: oci://${HARBOR_HOST}/${harbor_project}/${chart_name}:${version}"
    else
        log_error "Failed to push ${chart_name} to Harbor"
    fi

    rm -rf "$tmpdir" "$lockfile"
}

# ─── Parse .tgz filename ────────────────────────────────────────────────────

parse_tgz_filename() {
    local filename="$1"
    filename="${filename%.tgz}"
    if [[ "$filename" =~ ^(.+)-([vV]?[0-9]+\..+)$ ]]; then
        echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    fi
}

# ─── Lookup HTTP chart in manifest by name ───────────────────────────────────

lookup_chart() {
    local chart_name="$1"
    while IFS='|' read -r type source version harbor_project manifest_chart env_var; do
        [[ -z "$type" || "$type" == "#"* ]] && continue
        [[ "$type" == "http" ]] || continue
        if [[ "$manifest_chart" == "$chart_name" ]]; then
            echo "${source}|${version}|${harbor_project}|${manifest_chart}|${env_var}"
            return 0
        fi
    done < "$MANIFEST"
    return 1
}

# ─── HTTP Response Helper ───────────────────────────────────────────────────

respond() {
    local code="$1" body="${2:-}"
    local status_text
    case "$code" in
        200) status_text="OK" ;;
        202) status_text="Accepted" ;;
        404) status_text="Not Found" ;;
        *)   status_text="OK" ;;
    esac
    printf "HTTP/1.1 %s %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$code" "$status_text" "${#body}" "$body"
}

# ─── Connection Handler (called per connection via ncat -e) ──────────────────

handle_connection() {
    local first_line="" original_uri=""

    IFS= read -r first_line
    first_line="${first_line%%$'\r'}"
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [[ -z "$line" ]] && break
        case "$line" in
            X-Original-URI:*) original_uri="${line#X-Original-URI: }" ;;
        esac
    done

    local method path
    read -r method path _ <<< "$first_line"

    case "$path" in
        /sync)
            respond 200 "ok"

            [[ "$original_uri" == *.tgz ]] || return 0

            local filename parsed chart_name version
            filename=$(basename "$original_uri")
            parsed=$(parse_tgz_filename "$filename") || return 0
            chart_name="${parsed%%|*}"
            version="${parsed##*|}"

            log_info "Mirror: ${original_uri} -> chart=${chart_name} version=${version}"

            local entry
            entry=$(lookup_chart "$chart_name") || {
                log_warn "Chart not in manifest: ${chart_name}"
                return 0
            }

            local source manifest_ver harbor_project manifest_chart env_var
            IFS='|' read -r source manifest_ver harbor_project manifest_chart env_var <<< "$entry"

            sync_chart "$source" "$version" "$harbor_project" "$chart_name" &
            ;;
        /sync-all)
            respond 202 "Full sync started"
            while IFS='|' read -r type source version harbor_project chart_name env_var; do
                [[ -z "$type" || "$type" == "#"* ]] && continue
                [[ "$type" == "http" ]] || continue
                sync_chart "$source" "$version" "$harbor_project" "$chart_name" &
            done < "$MANIFEST"
            ;;
        /healthz)
            respond 200 "ok"
            ;;
        *)
            respond 404 "not found"
            ;;
    esac

    wait
}

# ─── Main ────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--handle" ]]; then
    handle_connection
    exit 0
fi

log_info "helm-sync starting on port ${LISTEN_PORT}"
log_info "Harbor: ${HARBOR_HOST} (user: ${HARBOR_USER})"
log_info "Manifest: ${MANIFEST}"

[[ -f "$MANIFEST" ]] || { log_error "Manifest not found: $MANIFEST"; exit 1; }
command -v helm &>/dev/null || { log_error "helm CLI not found"; exit 1; }

# Login to Harbor registry
if [[ -n "$HARBOR_PASS" ]]; then
    echo "$HARBOR_PASS" | helm registry login "$HARBOR_HOST" \
        --username "$HARBOR_USER" --password-stdin 2>/dev/null || log_warn "Harbor registry login failed"
fi

log_info "Listening on port ${LISTEN_PORT}..."

# Tail the log file to container stdout in background
tail -F "$LOGFILE" 2>/dev/null &

# ncat listen loop — each connection runs --handle as a subprocess
while true; do
    ncat -l -p "$LISTEN_PORT" -e "/opt/helm-sync/helm-sync.sh --handle" 2>/dev/null || {
        log_error "ncat exited unexpectedly, restarting..."
        sleep 1
    }
done
