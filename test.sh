#!/usr/bin/env bash
# =============================================================================
# test.sh — End-to-end verification of the airgap simulation
# =============================================================================
# Validates that all proxy endpoints, registry, and certificates are working.
#
# Usage:
#   ./test.sh                          # Test all (auto-detect proxy from /etc/hosts)
#   ./test.sh --proxy-ip 10.0.1.50    # Specify proxy VM IP
#   ./test.sh --quick                  # Skip slow tests (large downloads)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_CERT="${SCRIPT_DIR}/certs/ca-chain.pem"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_test()  { echo -e "${BOLD}[TEST]${NC}  $*"; }

PROXY_IP=""
QUICK=false
DOMAIN="example.com"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-ip) PROXY_IP="$2"; shift 2 ;;
    --quick)    QUICK=true; shift ;;
    --domain)   DOMAIN="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--proxy-ip IP] [--quick] [--domain DOMAIN]"
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# Auto-detect proxy IP from /etc/hosts
if [[ -z "$PROXY_IP" ]]; then
  PROXY_IP=$(grep "yum.${DOMAIN}" /etc/hosts 2>/dev/null | awk '{print $1}' | head -1)
  [[ -n "$PROXY_IP" ]] || PROXY_IP="127.0.0.1"
fi

[[ -f "$CA_CERT" ]] || { log_fail "CA cert not found: ${CA_CERT}"; exit 1; }

PASS=0
FAIL=0
SKIP=0

run_test() {
  local name="$1"
  shift
  log_test "$name"
  if "$@"; then
    log_ok "$name"
    PASS=$((PASS + 1))
  else
    log_fail "$name"
    FAIL=$((FAIL + 1))
  fi
}

skip_test() {
  local name="$1"
  log_warn "SKIP  $name"
  SKIP=$((SKIP + 1))
}

# Curl wrapper with CA cert (exported for bash -c subshells)
ccurl() {
  curl -L --cacert "$CA_CERT" --connect-timeout 10 --max-time 30 -sf "$@"
}
export -f ccurl
export CA_CERT

echo ""
echo -e "${BOLD}=== Airgap Simulation Verification ===${NC}"
echo "Proxy IP: ${PROXY_IP}"
echo "CA cert:  ${CA_CERT}"
echo ""

# ---- 1. Certificate Validation ----
echo -e "${BOLD}--- Certificate Chain ---${NC}"
run_test "Certificate chain validates" \
  openssl verify -CAfile "$CA_CERT" "${SCRIPT_DIR}/certs/server.pem"

run_test "Leaf cert has correct SANs" bash -c "
  openssl x509 -in '${SCRIPT_DIR}/certs/server.pem' -noout -ext subjectAltName 2>/dev/null \
    | grep -q 'yum.${DOMAIN}'
"

# ---- 2. YUM/RPM Proxy ----
echo ""
echo -e "${BOLD}--- yum.${DOMAIN} (RPM Proxy) ---${NC}"

run_test "RKE2 GPG key accessible" bash -c "
  ccurl 'https://yum.${DOMAIN}/rke2/public.key' | grep -qm1 'BEGIN PGP PUBLIC KEY BLOCK'
"

run_test "RKE2 common repodata" bash -c "
  ccurl 'https://yum.${DOMAIN}/rke2/latest/common/centos/9/noarch/repodata/repomd.xml' | grep -q '<repomd'
"

run_test "RKE2 1.34 repodata" bash -c "
  ccurl 'https://yum.${DOMAIN}/rke2/latest/1.34/centos/9/x86_64/repodata/repomd.xml' | grep -q '<repomd'
"

run_test "EPEL 9 repodata" bash -c "
  ccurl 'https://yum.${DOMAIN}/epel/9/Everything/x86_64/repodata/repomd.xml' | grep -q '<repomd'
"

run_test "EPEL GPG key accessible" bash -c "
  ccurl 'https://yum.${DOMAIN}/epel/RPM-GPG-KEY-EPEL-9' | grep -qm1 'BEGIN PGP PUBLIC KEY BLOCK'
"

# ---- 3. APT Proxy ----
echo ""
echo -e "${BOLD}--- apt.${DOMAIN} (APT Proxy) ---${NC}"

run_test "Debian bookworm Release file" bash -c "
  ccurl 'https://apt.${DOMAIN}/debian/dists/bookworm/Release' | grep -q 'Codename: bookworm'
"

run_test "Ubuntu noble Release file" bash -c "
  ccurl 'https://apt.${DOMAIN}/ubuntu/dists/noble/Release' | grep -q 'Codename: noble'
"

# ---- 4. Download Proxy ----
echo ""
echo -e "${BOLD}--- dl.${DOMAIN} (Cloud Images) ---${NC}"

run_test "Rocky 9 cloud image directory" bash -c "
  status=\$(curl --cacert '${CA_CERT}' -s -o /dev/null -w '%{http_code}' 'https://dl.${DOMAIN}/rocky/9/images/x86_64/')
  [[ \"\$status\" == '200' || \"\$status\" == '301' || \"\$status\" == '302' ]]
"

if ! $QUICK; then
  run_test "Rocky 9 GenericCloud qcow2 (HEAD)" bash -c "
    curl --cacert '${CA_CERT}' -sfI 'https://dl.${DOMAIN}/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2' \
      | grep -qi 'content-type'
  "
else
  skip_test "Rocky 9 GenericCloud qcow2 (HEAD) [--quick]"
fi

# ---- 5. Helm Chart Proxy ----
echo ""
echo -e "${BOLD}--- charts.${DOMAIN} (Helm Repos) ---${NC}"

run_test "cert-manager index.yaml" bash -c "
  ccurl 'https://charts.${DOMAIN}/jetstack/index.yaml' | grep -qm1 'apiVersion'
"

run_test "vault index.yaml" bash -c "
  ccurl 'https://charts.${DOMAIN}/hashicorp/index.yaml' | grep -qm1 'apiVersion'
"

run_test "harbor index.yaml" bash -c "
  ccurl 'https://charts.${DOMAIN}/goharbor/index.yaml' | grep -qm1 'apiVersion'
"

run_test "kube-prometheus-stack index.yaml" bash -c "
  ccurl 'https://charts.${DOMAIN}/prometheus-community/index.yaml' | grep -qm1 'apiVersion'
"

run_test "external-secrets index.yaml" bash -c "
  ccurl 'https://charts.${DOMAIN}/external-secrets/index.yaml' | grep -qm1 'apiVersion'
"

# ---- 6. Binary Static Server ----
echo ""
echo -e "${BOLD}--- bin.${DOMAIN} (Static Binaries) ---${NC}"

# These require bin/fetch-binaries.sh to have been run
if [[ -d "${SCRIPT_DIR}/bin/data" ]] && [[ -n "$(ls -A "${SCRIPT_DIR}/bin/data" 2>/dev/null)" ]]; then
  run_test "ArgoCD CLI binary" bash -c "
    status=\$(curl --cacert '${CA_CERT}' -s -o /dev/null -w '%{http_code}' 'https://bin.${DOMAIN}/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64')
    [[ \"\$status\" == '200' ]]
  "

  run_test "Gateway API CRD YAML" bash -c "
    ccurl 'https://bin.${DOMAIN}/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml' \
      | grep -qm1 'apiVersion\|kind'
  "
else
  skip_test "Binary static files (bin/data/ empty — run bin/fetch-binaries.sh)"
fi

# ---- 7. Bootstrap Registry ----
echo ""
echo -e "${BOLD}--- Bootstrap Registry (${PROXY_IP}:5000) ---${NC}"

run_test "Registry v2 API" bash -c "
  curl --cacert '${CA_CERT}' -k --connect-timeout 10 --max-time 30 -sfS 'https://${PROXY_IP}:5000/v2/' | grep -q '{}'
"

run_test "Registry catalog endpoint" bash -c "
  curl --cacert '${CA_CERT}' -k --connect-timeout 10 --max-time 30 -sfS 'https://${PROXY_IP}:5000/v2/_catalog' | grep -q 'repositories'
"

# ---- 8. Terraform Provider Mirror ----
echo ""
echo -e "${BOLD}--- Terraform Provider Mirror ---${NC}"

if [[ -f "$HOME/.terraformrc" ]] && grep -q "filesystem_mirror" "$HOME/.terraformrc" 2>/dev/null; then
  run_test "~/.terraformrc has filesystem_mirror" true
else
  run_test "~/.terraformrc has filesystem_mirror" false
fi

# ---- 9. validate_airgapped_prereqs() simulation ----
echo ""
echo -e "${BOLD}--- validate_airgapped_prereqs() Dry Run ---${NC}"

# Source the .env template to check all variables are defined
run_test "All required env vars defined in template" bash -c "
  source '${SCRIPT_DIR}/env/airgap.env.example' 2>/dev/null
  required=(
    BOOTSTRAP_REGISTRY UPSTREAM_PROXY_REGISTRY GIT_BASE_URL
    HELM_OCI_CERT_MANAGER HELM_OCI_CNPG HELM_OCI_CLUSTER_AUTOSCALER
    HELM_OCI_REDIS_OPERATOR HELM_OCI_VAULT HELM_OCI_HARBOR
    HELM_OCI_ARGOCD HELM_OCI_ARGO_ROLLOUTS HELM_OCI_ARGO_WORKFLOWS
    HELM_OCI_ARGO_EVENTS HELM_OCI_KASM HELM_OCI_KPS
    BINARY_URL_ARGOCD_CLI BINARY_URL_KUSTOMIZE BINARY_URL_KUBECONFORM
    CRD_SCHEMA_BASE_URL ARGO_ROLLOUTS_PLUGIN_URL
    PRIVATE_ROCKY_REPO_URL PRIVATE_RKE2_REPO_URL
  )
  for var in \"\${required[@]}\"; do
    [[ -n \"\${!var:-}\" ]] || { echo \"Missing: \$var\"; exit 1; }
  done
"

run_test "No github.com in binary URLs" bash -c "
  source '${SCRIPT_DIR}/env/airgap.env.example' 2>/dev/null
  for var in BINARY_URL_ARGOCD_CLI BINARY_URL_KUSTOMIZE BINARY_URL_KUBECONFORM ARGO_ROLLOUTS_PLUGIN_URL; do
    [[ \"\${!var:-}\" != *github.com* ]] || { echo \"\$var points to github.com\"; exit 1; }
  done
"

run_test "No githubusercontent.com in CRD URL" bash -c "
  source '${SCRIPT_DIR}/env/airgap.env.example' 2>/dev/null
  [[ \"\${CRD_SCHEMA_BASE_URL:-}\" != *githubusercontent.com* ]]
"

run_test "All HELM_OCI vars use oci:// protocol" bash -c "
  source '${SCRIPT_DIR}/env/airgap.env.example' 2>/dev/null
  for var in HELM_OCI_CERT_MANAGER HELM_OCI_CNPG HELM_OCI_VAULT HELM_OCI_HARBOR HELM_OCI_ARGOCD; do
    [[ \"\${!var:-}\" == oci://* ]] || { echo \"\$var is not oci://\"; exit 1; }
  done
"

# ---- Summary ----
echo ""
echo -e "${BOLD}========================================${NC}"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} / ${TOTAL} total"
echo -e "${BOLD}========================================${NC}"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
