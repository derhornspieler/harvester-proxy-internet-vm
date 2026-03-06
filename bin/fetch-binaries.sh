#!/usr/bin/env bash
# =============================================================================
# fetch-binaries.sh — Pre-download GitHub release binaries for airgapped serving
# =============================================================================
# GitHub releases use 302 redirect chains that break nginx proxy_pass.
# This script downloads binaries into bin/data/ with a path structure that
# mirrors the GitHub URL layout, so nginx can serve them statically.
#
# Usage:
#   ./bin/fetch-binaries.sh              # Download all binaries
#   ./bin/fetch-binaries.sh --list-only  # Just print what would be downloaded
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

LIST_ONLY=false
[[ "${1:-}" == "--list-only" ]] && LIST_ONLY=true

# =============================================================================
# Binary manifest: SOURCE_URL|LOCAL_PATH
# Local path mirrors the GitHub URL path (after github.com/)
# =============================================================================
BINARIES=(
  # ArgoCD CLI
  "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64|argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"

  # Kustomize
  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz|kubernetes-sigs/kustomize/releases/download/kustomize/v5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz"

  # Kubeconform
  "https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz|yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz"

  # Gateway API CRDs
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml|kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml"

  # Argo Rollouts Gateway API plugin
  "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.11.0/gatewayapi-plugin-linux-amd64|argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.5.0/gateway-api-plugin-linux-amd64"
)

# CRD schemas from datreeio/CRDs-catalog (raw.githubusercontent.com)
CRD_SCHEMAS=(
  # Gateway API CRDs
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/gateway.networking.k8s.io/gateway_v1.json|datreeio/CRDs-catalog/main/gateway.networking.k8s.io/gateway_v1.json"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/gateway.networking.k8s.io/httproute_v1.json|datreeio/CRDs-catalog/main/gateway.networking.k8s.io/httproute_v1.json"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/gateway.networking.k8s.io/grpcroute_v1.json|datreeio/CRDs-catalog/main/gateway.networking.k8s.io/grpcroute_v1.json"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/gateway.networking.k8s.io/referencegrant_v1beta1.json|datreeio/CRDs-catalog/main/gateway.networking.k8s.io/referencegrant_v1beta1.json"
  # cert-manager
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/cert-manager.io/certificate_v1.json|datreeio/CRDs-catalog/main/cert-manager.io/certificate_v1.json"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/cert-manager.io/issuer_v1.json|datreeio/CRDs-catalog/main/cert-manager.io/issuer_v1.json"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/cert-manager.io/clusterissuer_v1.json|datreeio/CRDs-catalog/main/cert-manager.io/clusterissuer_v1.json"
  # Argo Rollouts
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/argoproj.io/rollout_v1alpha1.json|datreeio/CRDs-catalog/main/argoproj.io/rollout_v1alpha1.json"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/argoproj.io/analysistemplate_v1alpha1.json|datreeio/CRDs-catalog/main/argoproj.io/analysistemplate_v1alpha1.json"
  # External Secrets
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/external-secrets.io/externalsecret_v1beta1.json|datreeio/CRDs-catalog/main/external-secrets.io/externalsecret_v1beta1.json"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/external-secrets.io/clustersecretstore_v1beta1.json|datreeio/CRDs-catalog/main/external-secrets.io/clustersecretstore_v1beta1.json"
)

# =============================================================================
# LIST MODE
# =============================================================================
if $LIST_ONLY; then
  echo ""
  echo "=== Binaries ==="
  for entry in "${BINARIES[@]}"; do
    IFS='|' read -r url path <<< "$entry"
    echo "  ${url}"
    echo "    → data/${path}"
  done
  echo ""
  echo "=== CRD Schemas ==="
  for entry in "${CRD_SCHEMAS[@]}"; do
    IFS='|' read -r url path <<< "$entry"
    echo "  ${url}"
    echo "    → data/${path}"
  done
  echo ""
  echo "Total: $((${#BINARIES[@]} + ${#CRD_SCHEMAS[@]})) files"
  exit 0
fi

# =============================================================================
# DOWNLOAD
# =============================================================================
command -v curl &>/dev/null || die "curl is required"

mkdir -p "$DATA_DIR"

download_file() {
  local url="$1" path="$2"
  local dest="${DATA_DIR}/${path}"
  local dest_dir
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir"

  if [[ -f "$dest" ]]; then
    log_ok "Already exists: ${path}"
    return 0
  fi

  log_info "Downloading: ${url}"
  if curl -fsSL --connect-timeout 30 --max-time 600 -o "$dest" "$url"; then
    log_ok "Saved: ${path} ($(du -h "$dest" | cut -f1))"
  else
    log_error "Failed to download: ${url}"
    rm -f "$dest"
    return 1
  fi
}

echo ""
log_info "=== Downloading binaries ==="
errors=0
for entry in "${BINARIES[@]}"; do
  IFS='|' read -r url path <<< "$entry"
  download_file "$url" "$path" || errors=$((errors + 1))
done

echo ""
log_info "=== Downloading CRD schemas ==="
for entry in "${CRD_SCHEMAS[@]}"; do
  IFS='|' read -r url path <<< "$entry"
  download_file "$url" "$path" || errors=$((errors + 1))
done

echo ""
if [[ $errors -gt 0 ]]; then
  log_warn "Completed with ${errors} error(s)"
  exit 1
fi
log_ok "All binaries downloaded to ${DATA_DIR}/"
log_info "Total size: $(du -sh "$DATA_DIR" | cut -f1)"
