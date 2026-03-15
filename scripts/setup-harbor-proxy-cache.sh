#!/usr/bin/env bash
# =============================================================================
# setup-harbor-proxy-cache.sh — Create Harbor proxy-cache projects
# =============================================================================
# Creates registry endpoints and proxy-cache projects for common container
# registries. Project names match the registry FQDN (e.g., docker.io, ghcr.io).
#
# Usage:
#   ./scripts/setup-harbor-proxy-cache.sh [--harbor-url URL] [--admin-pass PASS]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

HARBOR_URL="${HARBOR_URL:-http://127.0.0.1:8080}"
HARBOR_USER="${HARBOR_ADMIN_USER:-admin}"
HARBOR_PASS="${HARBOR_ADMIN_PASS:-Harbor12345}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harbor-url)  HARBOR_URL="$2";  shift 2 ;;
    --admin-pass)  HARBOR_PASS="$2"; shift 2 ;;
    --admin-user)  HARBOR_USER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--harbor-url URL] [--admin-user USER] [--admin-pass PASS]"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

API="${HARBOR_URL}/api/v2.0"
AUTH="${HARBOR_USER}:${HARBOR_PASS}"

# Verify connectivity
http_code=$(curl -sk -u "${AUTH}" -o /dev/null -w "%{http_code}" "${API}/users/current")
[[ "$http_code" = "200" ]] || die "Cannot authenticate to Harbor (HTTP ${http_code})"
log_ok "Authenticated to Harbor as ${HARBOR_USER}"

# =============================================================================
# Registry definitions: FQDN|HARBOR_TYPE|ENDPOINT_URL
# =============================================================================
REGISTRIES=(
  "docker.io|docker-hub|https://hub.docker.com"
  "ghcr.io|github-ghcr|https://ghcr.io"
  "quay.io|quay|https://quay.io"
  "registry.k8s.io|docker-registry|https://registry.k8s.io"
  "gcr.io|docker-registry|https://gcr.io"
  "public.ecr.aws|docker-registry|https://public.ecr.aws"
  "docker.elastic.co|docker-registry|https://docker.elastic.co"
  "registry.gitlab.com|docker-registry|https://registry.gitlab.com"
)

# =============================================================================
# Phase 1: Create all registry endpoints
# =============================================================================
log_info ""
log_info "=== Phase 1: Creating registry endpoints ==="

for entry in "${REGISTRIES[@]}"; do
  IFS='|' read -r fqdn type endpoint_url <<< "$entry"

  # Check if exists
  existing_id=$(curl -sk -u "${AUTH}" "${API}/registries" 2>/dev/null | \
    jq -r --arg n "$fqdn" '.[] | select(.name == $n) | .id' 2>/dev/null || echo "")

  if [[ -n "$existing_id" ]]; then
    log_ok "Registry '${fqdn}' exists (id=${existing_id})"
    continue
  fi

  payload=$(jq -n \
    --arg name "$fqdn" \
    --arg type "$type" \
    --arg url "$endpoint_url" \
    '{
      name: $name,
      type: $type,
      url: $url,
      insecure: false,
      credential: { type: "basic", access_key: "", access_secret: "" }
    }')

  resp_code=$(curl -sk -u "${AUTH}" -X POST "${API}/registries" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -o /dev/null -w "%{http_code}" 2>&1)

  case "$resp_code" in
    201) log_ok "Created registry endpoint: ${fqdn}" ;;
    409) log_warn "Registry '${fqdn}' already exists (409)" ;;
    *)   log_error "Failed to create registry '${fqdn}': HTTP ${resp_code}" ;;
  esac
done

# Wait for endpoints to settle
sleep 2

# =============================================================================
# Phase 2: Create proxy-cache projects
# =============================================================================
log_info ""
log_info "=== Phase 2: Creating proxy-cache projects ==="

# Fetch all registry IDs
all_registries=$(curl -sk -u "${AUTH}" "${API}/registries" 2>/dev/null)

for entry in "${REGISTRIES[@]}"; do
  IFS='|' read -r fqdn type endpoint_url <<< "$entry"

  # Get registry ID
  registry_id=$(echo "$all_registries" | jq -r --arg n "$fqdn" '.[] | select(.name == $n) | .id' 2>/dev/null || echo "")

  if [[ -z "$registry_id" ]]; then
    log_error "No registry endpoint found for '${fqdn}' — skipping project"
    continue
  fi

  # Check if project exists
  project_exists=$(curl -sk -u "${AUTH}" "${API}/projects?name=${fqdn}" 2>/dev/null | \
    jq -r --arg n "$fqdn" '.[] | select(.name == $n) | .name' 2>/dev/null || echo "")

  if [[ -n "$project_exists" ]]; then
    log_ok "Project '${fqdn}' already exists"
    continue
  fi

  payload=$(jq -n \
    --arg name "$fqdn" \
    --argjson rid "$registry_id" \
    '{
      project_name: $name,
      public: true,
      metadata: { public: "true" },
      registry_id: $rid
    }')

  resp_code=$(curl -sk -u "${AUTH}" -X POST "${API}/projects" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -o /dev/null -w "%{http_code}" 2>&1)

  case "$resp_code" in
    201) log_ok "Created proxy-cache project: ${fqdn}" ;;
    409) log_warn "Project '${fqdn}' already exists (409)" ;;
    *)   log_error "Failed to create project '${fqdn}': HTTP ${resp_code}" ;;
  esac
done

# =============================================================================
# Phase 3: Create robot account for helm-sync
# =============================================================================
log_info ""
log_info "=== Phase 3: Creating helm-sync robot account ==="

robot_payload=$(jq -n '{
  name: "helm-sync",
  description: "Robot account for helm-sync OCI chart pushing",
  duration: -1,
  level: "system",
  disable: false,
  permissions: [
    {
      namespace: "*",
      kind: "project",
      access: [
        { resource: "repository", action: "push" },
        { resource: "repository", action: "pull" },
        { resource: "artifact", action: "read" },
        { resource: "artifact", action: "create" },
        { resource: "tag", action: "create" },
        { resource: "tag", action: "list" }
      ]
    }
  ]
}')

robot_response=$(curl -sk -u "${AUTH}" -X POST "${API}/robots" \
  -H "Content-Type: application/json" \
  -d "$robot_payload" \
  -w "\n%{http_code}" 2>&1)

robot_http=$(echo "$robot_response" | tail -1)
robot_body=$(echo "$robot_response" | sed '$d')

case "$robot_http" in
  201)
    robot_name=$(echo "$robot_body" | jq -r '.name')
    robot_secret=$(echo "$robot_body" | jq -r '.secret')
    log_ok "Created robot account: ${robot_name}"
    echo ""
    echo "========================================="
    echo "  Robot Account Credentials"
    echo "========================================="
    echo "  Username: ${robot_name}"
    echo "  Password: ${robot_secret}"
    echo "========================================="
    echo ""
    echo "Update .env with:"
    echo "  HARBOR_USER=${robot_name}"
    echo "  HARBOR_PASS=${robot_secret}"
    ;;
  409) log_warn "Robot account 'helm-sync' already exists" ;;
  *)   log_error "Failed to create robot account: HTTP ${robot_http}" ;;
esac

log_info ""
log_ok "Harbor proxy-cache setup complete!"
log_info "Pull images via: harbor.aegisgroup.ch/<registry>/<image>:<tag>"
log_info "  Example: harbor.aegisgroup.ch/docker.io/library/nginx:latest"
