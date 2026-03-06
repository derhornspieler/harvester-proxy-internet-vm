#!/usr/bin/env bash
# =============================================================================
# populate-bootstrap-registry.sh — Populate the local bootstrap registry
# =============================================================================
# Wrapper around scripts/prepare-bootstrap-registry.sh that targets the local
# Docker registry running in the docker-compose stack.
#
# Usage:
#   ./registry/populate-bootstrap-registry.sh [--list-only] [--charts-only]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRGAP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${AIRGAP_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

UPSTREAM_SCRIPT="${REPO_ROOT}/scripts/prepare-bootstrap-registry.sh"
[[ -f "$UPSTREAM_SCRIPT" ]] || die "Not found: ${UPSTREAM_SCRIPT}"

# Detect proxy VM IP from .env or docker-compose
if [[ -z "${BOOTSTRAP_REGISTRY:-}" ]]; then
  # Try to detect from running containers
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'airgap-registry'; then
    # Get the host's IP that other machines can reach
    HOST_IP=$(hostname -I | awk '{print $1}')
    export BOOTSTRAP_REGISTRY="${HOST_IP}:5000"
    log_info "Auto-detected BOOTSTRAP_REGISTRY=${BOOTSTRAP_REGISTRY}"
  else
    die "BOOTSTRAP_REGISTRY not set and registry container not running"
  fi
fi

log_info "Populating bootstrap registry: ${BOOTSTRAP_REGISTRY}"
log_info "Using upstream script: ${UPSTREAM_SCRIPT}"
echo ""

exec "$UPSTREAM_SCRIPT" "$@"
