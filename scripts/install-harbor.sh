#!/usr/bin/env bash
# =============================================================================
# install-harbor.sh — Install Harbor on the same VM (co-located / internal mode)
# =============================================================================
# Downloads and configures the official Harbor offline installer.
# After running this script, Harbor listens on localhost:8080 (HTTP).
# nginx's harbor.conf provides TLS termination at harbor.$DOMAIN.
#
# Usage:
#   ./scripts/install-harbor.sh [--version 2.12.2]
#
# Prerequisites:
#   - Docker + Docker Compose
#   - .env file with HARBOR_HOST, HARBOR_PASS
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${PROJECT_DIR}/.env"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

# Defaults
HARBOR_VERSION="2.12.2"
HARBOR_INSTALL_DIR="/opt/harbor"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) HARBOR_VERSION="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--version VERSION]"
            echo ""
            echo "  --version VERSION   Harbor version (default: ${HARBOR_VERSION})"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

DOMAIN="${DOMAIN:-example.com}"
HARBOR_ADMIN_PASS="${HARBOR_PASS:-Harbor12345}"

log_info "Installing Harbor v${HARBOR_VERSION} (co-located mode)"
log_info "Harbor will listen on HTTP :8080 (nginx handles TLS)"
log_info "External URL: https://harbor.${DOMAIN}"
echo ""

# Check prerequisites
command -v docker &>/dev/null || die "docker not found"
if ! docker compose version &>/dev/null; then
    die "docker compose not found"
fi

# Download Harbor offline installer
INSTALLER_URL="https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-offline-installer-v${HARBOR_VERSION}.tgz"
INSTALLER_TGZ="/tmp/harbor-installer-v${HARBOR_VERSION}.tgz"

if [[ ! -f "$INSTALLER_TGZ" ]]; then
    log_info "Downloading Harbor offline installer..."
    curl -fSL -o "$INSTALLER_TGZ" "$INSTALLER_URL"
else
    log_info "Using cached installer: ${INSTALLER_TGZ}"
fi

# Extract
log_info "Extracting to ${HARBOR_INSTALL_DIR}..."
sudo mkdir -p "$(dirname "$HARBOR_INSTALL_DIR")"
sudo tar -xzf "$INSTALLER_TGZ" -C "$(dirname "$HARBOR_INSTALL_DIR")"

# Configure harbor.yml
HARBOR_YML="${HARBOR_INSTALL_DIR}/harbor.yml"
sudo cp "${HARBOR_INSTALL_DIR}/harbor.yml.tmpl" "$HARBOR_YML"

# Patch harbor.yml for co-located mode:
#   - hostname = harbor.$DOMAIN
#   - Disable HTTPS (nginx handles TLS)
#   - Set HTTP port to 8080
#   - Set admin password
sudo sed -i "s|^hostname:.*|hostname: harbor.${DOMAIN}|" "$HARBOR_YML"
sudo sed -i "s|^  port: 80$|  port: 8080|" "$HARBOR_YML"
sudo sed -i "s|^harbor_admin_password:.*|harbor_admin_password: ${HARBOR_ADMIN_PASS}|" "$HARBOR_YML"
sudo sed -i "s|^external_url:.*|external_url: https://harbor.${DOMAIN}|" "$HARBOR_YML"

# Disable HTTPS in harbor.yml (comment out the https block)
sudo sed -i '/^https:/,/^[^ ]/{/^https:/s/^/#/; /^  /s/^/#/}' "$HARBOR_YML"

log_info "Harbor configuration written to ${HARBOR_YML}"
log_warn "Review ${HARBOR_YML} before proceeding"
echo ""

# Run installer
log_info "Running Harbor installer..."
cd "$HARBOR_INSTALL_DIR"
sudo ./install.sh --with-trivy

echo ""
log_info "Harbor installed successfully!"
log_info ""
log_info "Harbor is listening on http://127.0.0.1:8080"
log_info "nginx will proxy https://harbor.${DOMAIN} → http://127.0.0.1:8080"
log_info ""
log_info "Next steps:"
log_info "  1. Set HARBOR_HOST=harbor.${DOMAIN} in .env"
log_info "  2. Run ./scripts/configure.sh"
log_info "  3. Restart nginx: docker compose restart nginx"
log_info "  4. Log in: https://harbor.${DOMAIN} (admin / ${HARBOR_ADMIN_PASS})"
log_info "  5. Create a robot account for helm-sync (see README)"
