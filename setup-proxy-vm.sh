#!/usr/bin/env bash
# =============================================================================
# setup-proxy-vm.sh — Provision a dedicated proxy VM for airgap simulation
# =============================================================================
# Installs Docker, copies configs/certs, adds /etc/hosts entries, and starts
# the docker-compose stack on the target VM.
#
# Usage:
#   ./setup-proxy-vm.sh <proxy-vm-ip> [--domain example.com] [--ssh-user rocky]
#
# Prerequisites:
#   - SSH access to the proxy VM (key-based)
#   - Certs generated (run certs/generate-certs.sh first)
#   - Binaries downloaded (run bin/fetch-binaries.sh first)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

# Defaults
DOMAIN="example.com"
SSH_USER="rocky"

# Parse arguments
PROXY_IP="${1:-}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)   DOMAIN="$2";   shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 <proxy-vm-ip> [--domain DOMAIN] [--ssh-user USER]"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$PROXY_IP" ]] || die "Usage: $0 <proxy-vm-ip>"

# Validate certs exist
for f in certs/server-fullchain.pem certs/server-key.pem certs/ca-chain.pem; do
  [[ -f "${SCRIPT_DIR}/${f}" ]] || die "Missing ${f} — run certs/generate-certs.sh first"
done

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
SSH_CMD="ssh ${SSH_OPTS} ${SSH_USER}@${PROXY_IP}"
SCP_CMD="scp ${SSH_OPTS}"

log_info "Provisioning airgap proxy on ${PROXY_IP} (user: ${SSH_USER})"

# ---- Step 1: Install Docker ----
log_info "Installing Docker on ${PROXY_IP}..."
${SSH_CMD} bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

# Configure Docker daemon before first start — keep networks out of 172.16-18.x.x
sudo mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat <<'DAEMON_JSON' | sudo tee /etc/docker/daemon.json >/dev/null
{
  "bip": "192.168.200.1/24",
  "fixed-cidr": "192.168.200.0/24",
  "default-address-pools": [
    { "base": "10.10.0.0/16", "size": 24 }
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
DAEMON_JSON
  echo "Docker daemon.json configured"
fi

if command -v docker &>/dev/null; then
  echo "Docker already installed: $(docker --version)"
else
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$(whoami)" || true
  echo "Docker installed: $(docker --version)"
fi
REMOTE_SCRIPT

# ---- Step 2: Create directory structure ----
log_info "Creating directory structure..."
${SSH_CMD} "mkdir -p ~/airgap-simulation/{certs,nginx/{conf.d,includes},registry,bin/data}"

# ---- Step 3: Copy all config files ----
log_info "Copying configuration files..."

# Certs
${SCP_CMD} "${SCRIPT_DIR}/certs/server-fullchain.pem" \
           "${SCRIPT_DIR}/certs/server-key.pem" \
           "${SCRIPT_DIR}/certs/ca-chain.pem" \
           "${SSH_USER}@${PROXY_IP}:~/airgap-simulation/certs/"

# Nginx
${SCP_CMD} "${SCRIPT_DIR}/nginx/nginx.conf" \
           "${SSH_USER}@${PROXY_IP}:~/airgap-simulation/nginx/"
${SCP_CMD} "${SCRIPT_DIR}/nginx/conf.d/"*.conf \
           "${SSH_USER}@${PROXY_IP}:~/airgap-simulation/nginx/conf.d/"
${SCP_CMD} "${SCRIPT_DIR}/nginx/includes/"*.conf \
           "${SSH_USER}@${PROXY_IP}:~/airgap-simulation/nginx/includes/"

# Registry
${SCP_CMD} "${SCRIPT_DIR}/registry/config.yml" \
           "${SSH_USER}@${PROXY_IP}:~/airgap-simulation/registry/"

# Docker Compose
${SCP_CMD} "${SCRIPT_DIR}/docker-compose.yaml" \
           "${SSH_USER}@${PROXY_IP}:~/airgap-simulation/"

# Binaries (if present)
if [[ -d "${SCRIPT_DIR}/bin/data" ]] && [[ -n "$(ls -A "${SCRIPT_DIR}/bin/data" 2>/dev/null)" ]]; then
  log_info "Copying pre-downloaded binaries (this may take a while)..."
  ${SCP_CMD} -r "${SCRIPT_DIR}/bin/data/" \
             "${SSH_USER}@${PROXY_IP}:~/airgap-simulation/bin/"
else
  log_warn "bin/data/ is empty — run bin/fetch-binaries.sh first, then re-run setup"
fi

# ---- Step 4: Trust the private CA on the proxy VM ----
log_info "Installing private CA on proxy VM..."
${SSH_CMD} bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
CA_SRC=~/airgap-simulation/certs/ca-chain.pem
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}" in
    rocky|rhel|centos|fedora)
      sudo cp "$CA_SRC" /etc/pki/ca-trust/source/anchors/airgap-proxy-ca.pem
      sudo update-ca-trust
      ;;
    debian|ubuntu)
      sudo cp "$CA_SRC" /usr/local/share/ca-certificates/airgap-proxy-ca.crt
      sudo update-ca-certificates
      ;;
    alpine)
      sudo apk add --no-cache ca-certificates
      sudo cp "$CA_SRC" /usr/local/share/ca-certificates/airgap-proxy-ca.crt
      sudo update-ca-certificates
      ;;
    *)
      echo "Unknown distro ${ID:-}, attempting RHEL-style trust"
      sudo cp "$CA_SRC" /etc/pki/ca-trust/source/anchors/airgap-proxy-ca.pem
      sudo update-ca-trust
      ;;
  esac
else
  sudo cp "$CA_SRC" /etc/pki/ca-trust/source/anchors/airgap-proxy-ca.pem
  sudo update-ca-trust
fi
echo "CA trust updated"
REMOTE_SCRIPT

# ---- Step 5: Add /etc/hosts entries on proxy VM ----
log_info "Adding /etc/hosts entries on proxy VM..."
HOSTS_ENTRY="127.0.0.1  yum.${DOMAIN} apt.${DOMAIN} apk.${DOMAIN} dl.${DOMAIN} charts.${DOMAIN} bin.${DOMAIN} go.${DOMAIN} npm.${DOMAIN} pypi.${DOMAIN} maven.${DOMAIN} crates.${DOMAIN} proxy.${DOMAIN}"
${SSH_CMD} bash -s <<REMOTE_SCRIPT
set -euo pipefail
if ! grep -q "yum.${DOMAIN}" /etc/hosts; then
  echo "${HOSTS_ENTRY}" | sudo tee -a /etc/hosts >/dev/null
  echo "Added /etc/hosts entries"
else
  echo "/etc/hosts entries already present"
fi
REMOTE_SCRIPT

# ---- Step 6: Start docker-compose stack ----
log_info "Starting docker-compose stack..."
${SSH_CMD} "cd ~/airgap-simulation && docker compose up -d"

# ---- Step 7: Wait for healthy ----
log_info "Waiting for services to become healthy..."
${SSH_CMD} bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
for i in $(seq 1 30); do
  nginx_ok=false
  registry_ok=false
  squid_ok=false
  docker inspect --format='{{.State.Health.Status}}' airgap-nginx 2>/dev/null | grep -q healthy && nginx_ok=true
  docker inspect --format='{{.State.Health.Status}}' airgap-registry 2>/dev/null | grep -q healthy && registry_ok=true
  docker inspect --format='{{.State.Health.Status}}' airgap-squid 2>/dev/null | grep -q healthy && squid_ok=true
  if $nginx_ok && $registry_ok && $squid_ok; then
    echo "All services healthy"
    exit 0
  fi
  echo "  Waiting... (nginx=$nginx_ok registry=$registry_ok squid=$squid_ok)"
  sleep 2
done
echo "WARNING: Services did not become healthy within 60s"
docker compose ps
exit 1
REMOTE_SCRIPT

# ---- Step 8: Add /etc/hosts on local dev VM ----
log_info "Adding /etc/hosts entries on local dev VM..."
LOCAL_HOSTS="${PROXY_IP}  yum.${DOMAIN} apt.${DOMAIN} apk.${DOMAIN} dl.${DOMAIN} charts.${DOMAIN} bin.${DOMAIN} go.${DOMAIN} npm.${DOMAIN} pypi.${DOMAIN} maven.${DOMAIN} crates.${DOMAIN} proxy.${DOMAIN}"
if ! grep -q "yum.${DOMAIN}" /etc/hosts; then
  echo "$LOCAL_HOSTS" | sudo tee -a /etc/hosts >/dev/null
  log_ok "Added local /etc/hosts entries"
else
  log_ok "Local /etc/hosts entries already present"
fi

echo ""
log_ok "Airgap proxy deployed successfully on ${PROXY_IP}"
echo ""
log_info "Services:"
log_info "  RPM repos:       https://yum.${DOMAIN}"
log_info "  APT repos:       https://apt.${DOMAIN}"
log_info "  APK repos:       https://apk.${DOMAIN}"
log_info "  Cloud images:    https://dl.${DOMAIN}"
log_info "  Helm charts:     https://charts.${DOMAIN}"
log_info "  Binaries:        https://bin.${DOMAIN}"
log_info "  Go modules:      https://go.${DOMAIN}"
log_info "  npm packages:    https://npm.${DOMAIN}"
log_info "  PyPI packages:   https://pypi.${DOMAIN}"
log_info "  Maven artifacts: https://maven.${DOMAIN}"
log_info "  Rust crates:     https://crates.${DOMAIN}"
log_info "  HTTP proxy:      http://proxy.${DOMAIN}:3128"
log_info "  Registry:        ${PROXY_IP}:5000"
echo ""
log_info "CA chain:          certs/ca-chain.pem"
log_info "Test with:         curl --cacert certs/ca-chain.pem https://yum.${DOMAIN}/rke2/public.key"
