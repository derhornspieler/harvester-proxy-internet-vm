#!/usr/bin/env bash
# =============================================================================
# sync-helm-oci.sh — Pull Helm charts and push to Harbor as OCI artifacts
# =============================================================================
# Reads charts.manifest, pulls each chart, creates Harbor projects, and pushes
# charts as OCI artifacts. Generates HELM_OCI_* env var assignments.
#
# Usage:
#   ./helm-oci/sync-helm-oci.sh --harbor harbor.example.com           # Sync all
#   ./helm-oci/sync-helm-oci.sh --harbor harbor.example.com --dry-run # Preview
#   ./helm-oci/sync-helm-oci.sh --harbor harbor.example.com --generate-env  # Output env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/charts.manifest"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

# Defaults
HARBOR_HOST=""
DRY_RUN=false
GENERATE_ENV=false
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harbor)       HARBOR_HOST="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --generate-env) GENERATE_ENV=true; shift ;;
    -h|--help)
      echo "Usage: $0 --harbor HARBOR_HOST [--dry-run] [--generate-env]"
      echo ""
      echo "  --harbor HOST     Harbor hostname (e.g. harbor.example.com)"
      echo "  --dry-run         Preview what would be synced (no push)"
      echo "  --generate-env    Output HELM_OCI_* environment variable assignments"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$HARBOR_HOST" ]] || die "--harbor is required"
[[ -f "$MANIFEST" ]]    || die "Manifest not found: ${MANIFEST}"
command -v helm &>/dev/null || die "helm CLI not found"

# Harbor login
if ! $DRY_RUN && ! $GENERATE_ENV; then
  if [[ -n "$HARBOR_PASS" ]]; then
    echo "$HARBOR_PASS" | helm registry login "$HARBOR_HOST" --username "$HARBOR_USER" --password-stdin 2>/dev/null || true
  fi
fi

# Track created projects to avoid duplicates
declare -A CREATED_PROJECTS
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ENV_OUTPUT=()
errors=0

log_info "Reading manifest: ${MANIFEST}"
echo ""

while IFS='|' read -r type source version harbor_project chart_name env_var; do
  # Skip comments and blank lines
  [[ -z "$type" || "$type" == "#"* ]] && continue

  oci_url="oci://${HARBOR_HOST}/${harbor_project}/${chart_name}"

  # Generate-env mode: just output variable assignments
  if $GENERATE_ENV; then
    ENV_OUTPUT+=("${env_var}=\"${oci_url}\"")
    continue
  fi

  log_info "${chart_name} (${type}) — ${source} v${version}"
  log_info "  Target: ${oci_url}"

  if $DRY_RUN; then
    continue
  fi

  # Create Harbor project if needed
  if [[ -z "${CREATED_PROJECTS[$harbor_project]:-}" ]]; then
    log_info "  Creating Harbor project: ${harbor_project}"
    # Use Harbor API to create project (ignore 409 = already exists)
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "https://${HARBOR_HOST}/api/v2.0/projects" \
      -H "Content-Type: application/json" \
      -u "${HARBOR_USER}:${HARBOR_PASS}" \
      -d "{\"project_name\": \"${harbor_project}\", \"public\": true}" 2>/dev/null || echo "000")
    case "$status" in
      201) log_ok "  Project created: ${harbor_project}" ;;
      409) log_ok "  Project exists: ${harbor_project}" ;;
      *)   log_warn "  Project creation returned HTTP ${status} (may need manual creation)" ;;
    esac
    CREATED_PROJECTS[$harbor_project]=1
  fi

  # Pull chart
  case "$type" in
    http)
      # Determine repo alias from chart_name or harbor_project
      repo_alias=$(echo "$harbor_project" | tr '.' '-' | tr '/' '-')
      helm repo add "$repo_alias" "$source" 2>/dev/null || true
      helm repo update "$repo_alias" 2>/dev/null || true

      if [[ "$version" == "latest" ]]; then
        # Search for latest version
        helm pull "${repo_alias}/${chart_name}" -d "$TMPDIR" 2>/dev/null || {
          log_error "  Failed to pull ${chart_name} (latest) from ${source}"
          errors=$((errors + 1))
          continue
        }
      else
        helm pull "${repo_alias}/${chart_name}" --version "$version" -d "$TMPDIR" 2>/dev/null || {
          log_error "  Failed to pull ${chart_name} v${version} from ${source}"
          errors=$((errors + 1))
          continue
        }
      fi
      ;;
    oci)
      if [[ "$version" == "latest" ]]; then
        helm pull "oci://${source}/${chart_name}" -d "$TMPDIR" 2>/dev/null || {
          log_error "  Failed to pull oci://${source}/${chart_name}"
          errors=$((errors + 1))
          continue
        }
      else
        helm pull "oci://${source}/${chart_name}" --version "$version" -d "$TMPDIR" 2>/dev/null || {
          log_error "  Failed to pull oci://${source}/${chart_name} v${version}"
          errors=$((errors + 1))
          continue
        }
      fi
      ;;
    *)
      log_warn "  Unknown type: ${type} — skipping"
      continue
      ;;
  esac

  # Find the downloaded tarball
  tarball=$(ls "${TMPDIR}/${chart_name}"-*.tgz 2>/dev/null | head -1)
  if [[ -z "$tarball" ]]; then
    log_error "  No tarball found for ${chart_name}"
    errors=$((errors + 1))
    continue
  fi

  # Push to Harbor as OCI
  if helm push "$tarball" "oci://${HARBOR_HOST}/${harbor_project}" 2>/dev/null; then
    log_ok "  Pushed: ${oci_url}"
  else
    log_error "  Failed to push ${chart_name} to Harbor"
    errors=$((errors + 1))
  fi

  rm -f "$tarball"
done < "$MANIFEST"

# Output env vars
if $GENERATE_ENV; then
  echo ""
  echo "# Helm OCI URLs for AIRGAPPED=true (generated by sync-helm-oci.sh)"
  echo "# Add these to scripts/.env"
  echo ""
  for line in "${ENV_OUTPUT[@]}"; do
    echo "$line"
  done
  exit 0
fi

echo ""
if [[ $errors -gt 0 ]]; then
  log_warn "Completed with ${errors} error(s)"
  exit 1
fi

if $DRY_RUN; then
  log_ok "Dry run complete — no charts pushed"
else
  log_ok "All charts synced to Harbor (${HARBOR_HOST})"
  echo ""
  log_info "Generate env vars with: $0 --harbor ${HARBOR_HOST} --generate-env"
fi
