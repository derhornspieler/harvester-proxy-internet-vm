#!/usr/bin/env bash
# =============================================================================
# fetch-providers.sh — Download Terraform providers for filesystem mirror
# =============================================================================
# Downloads the 3 required Terraform providers and generates a ~/.terraformrc
# pointing to the local mirror directory. Run on the dev VM.
#
# Usage:
#   ./terraform/fetch-providers.sh [--mirror-dir DIR]
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

MIRROR_DIR="${SCRIPT_DIR}/providers"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mirror-dir) MIRROR_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--mirror-dir DIR]"
      echo ""
      echo "Downloads Terraform providers and generates ~/.terraformrc"
      echo "Default mirror dir: ${SCRIPT_DIR}/providers"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v terraform &>/dev/null || die "terraform CLI not found"

# Provider specifications: NAMESPACE/TYPE VERSION
PROVIDERS=(
  "rancher/rancher2:6.0.0"
  "harvester/harvester:0.6.7"
  "hashicorp/null:3.2.4"
)

OS="linux"
ARCH="amd64"

mkdir -p "$MIRROR_DIR"

log_info "Downloading Terraform providers to: ${MIRROR_DIR}"
echo ""

for spec in "${PROVIDERS[@]}"; do
  IFS=':' read -r provider version <<< "$spec"
  namespace=$(echo "$provider" | cut -d'/' -f1)
  type=$(echo "$provider" | cut -d'/' -f2)

  # Mirror directory structure: registry.terraform.io/NAMESPACE/TYPE/VERSION/OS_ARCH
  provider_dir="${MIRROR_DIR}/registry.terraform.io/${namespace}/${type}"
  zip_name="terraform-provider-${type}_${version}_${OS}_${ARCH}.zip"
  zip_path="${provider_dir}/${zip_name}"

  if [[ -f "$zip_path" ]]; then
    log_ok "Already exists: ${provider} v${version}"
    continue
  fi

  mkdir -p "$provider_dir"

  # Determine download URL based on namespace
  case "$namespace" in
    hashicorp)
      url="https://releases.hashicorp.com/terraform-provider-${type}/${version}/${zip_name}"
      ;;
    rancher)
      url="https://github.com/rancher/terraform-provider-${type}/releases/download/v${version}/${zip_name}"
      ;;
    harvester)
      url="https://github.com/harvester/terraform-provider-${type}/releases/download/v${version}/${zip_name}"
      ;;
    *)
      log_warn "Unknown namespace ${namespace} — skipping"
      continue
      ;;
  esac

  log_info "Downloading ${provider} v${version}..."
  if curl -fsSL --connect-timeout 30 --max-time 300 -o "$zip_path" "$url"; then
    log_ok "Downloaded: ${zip_name} ($(du -h "$zip_path" | cut -f1))"
  else
    log_error "Failed to download: ${url}"
    rm -f "$zip_path"
  fi
done

# Generate ~/.terraformrc
TERRAFORMRC="$HOME/.terraformrc"
log_info ""
log_info "Generating ${TERRAFORMRC}..."

MIRROR_ABS=$(cd "$MIRROR_DIR" && pwd)

if [[ -f "$TERRAFORMRC" ]]; then
  if grep -q "filesystem_mirror" "$TERRAFORMRC"; then
    log_warn "${TERRAFORMRC} already has a filesystem_mirror block"
    log_warn "Verify it points to: ${MIRROR_ABS}"
    echo ""
    log_ok "Providers downloaded. Verify your ~/.terraformrc manually."
    exit 0
  fi
  log_warn "Backing up existing ${TERRAFORMRC} to ${TERRAFORMRC}.bak"
  cp "$TERRAFORMRC" "${TERRAFORMRC}.bak"
fi

cat > "$TERRAFORMRC" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${MIRROR_ABS}"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF

log_ok "Generated ${TERRAFORMRC}"
echo ""
log_info "Provider mirror contents:"
find "$MIRROR_ABS" -name '*.zip' -exec ls -lh {} \; 2>/dev/null || true
echo ""
log_ok "Terraform provider mirror ready"
