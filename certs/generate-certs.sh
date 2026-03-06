#!/usr/bin/env bash
# =============================================================================
# generate-certs.sh — Generate airgap proxy intermediate CA + multi-SAN leaf cert
# =============================================================================
# Creates an intermediate CA (signed by Root CA) and a leaf
# certificate with SANs for all airgap proxy hostnames.
#
# Usage:
#   ./certs/generate-certs.sh [--pki-dir /path/to/pki] [--domain example.com] [-f]
#
# Prerequisites:
#   - Root CA at <pki-dir>/roots/root-ca.pem
#   - openssl CLI
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$@"; exit 1; }

# Defaults
PKI_DIR="${PKI_DIR:-./pki}"
DOMAIN="example.com"
FORCE=false
ORG="${CERT_ORG:-Example Org}"
INTERMEDIATE_DAYS=1825   # 5 years
LEAF_DAYS=365            # 1 year
INTERMEDIATE_NAME="airgap-proxy"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pki-dir) PKI_DIR="$2";  shift 2 ;;
    --domain)  DOMAIN="$2";   shift 2 ;;
    -f)        FORCE=true;    shift ;;
    -h|--help)
      echo "Usage: $0 [--pki-dir DIR] [--domain DOMAIN] [-f]"
      echo ""
      echo "  --pki-dir DIR   Path to PKI directory (default: ./pki)"
      echo "  --domain DOMAIN Base domain (default: example.com)"
      echo "  -f              Force overwrite existing certs"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

# Validate PKI
ROOT_CERT="${PKI_DIR}/roots/root-ca.pem"
ROOT_KEY="${PKI_DIR}/roots/root-ca-key.pem"
[[ -f "$ROOT_CERT" ]] || die "Root CA cert not found: ${ROOT_CERT}"
[[ -f "$ROOT_KEY" ]]  || die "Root CA key not found: ${ROOT_KEY}"

# Output file paths
INTERMEDIATE_CERT="${OUTPUT_DIR}/${INTERMEDIATE_NAME}-ca.pem"
INTERMEDIATE_KEY="${OUTPUT_DIR}/${INTERMEDIATE_NAME}-ca-key.pem"
CHAIN="${OUTPUT_DIR}/ca-chain.pem"
LEAF_CERT="${OUTPUT_DIR}/server.pem"
LEAF_KEY="${OUTPUT_DIR}/server-key.pem"
LEAF_FULLCHAIN="${OUTPUT_DIR}/server-fullchain.pem"

# SANs for the leaf cert
SANS=(
  "yum.${DOMAIN}"
  "apt.${DOMAIN}"
  "dl.${DOMAIN}"
  "charts.${DOMAIN}"
  "bin.${DOMAIN}"
  "harbor.${DOMAIN}"
)

# Idempotency check — skip if all certs exist and are valid
check_existing() {
  local all_exist=true
  for f in "$INTERMEDIATE_CERT" "$INTERMEDIATE_KEY" "$CHAIN" \
           "$LEAF_CERT" "$LEAF_KEY" "$LEAF_FULLCHAIN"; do
    [[ -f "$f" ]] || { all_exist=false; break; }
  done

  if $all_exist && ! $FORCE; then
    # Verify chain is valid
    if openssl verify -CAfile "$CHAIN" "$LEAF_CERT" >/dev/null 2>&1; then
      # Check expiry (warn if < 30 days)
      local end_date
      end_date=$(openssl x509 -in "$LEAF_CERT" -noout -enddate | cut -d= -f2)
      local end_epoch
      end_epoch=$(date -d "$end_date" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "$end_date" +%s 2>/dev/null || echo 0)
      local now_epoch
      now_epoch=$(date +%s)
      local days_left=$(( (end_epoch - now_epoch) / 86400 ))

      if [[ $days_left -gt 30 ]]; then
        log "Existing certs are valid (${days_left} days remaining) — skipping generation"
        log "Use -f to force regeneration"
        exit 0
      else
        warn "Certs expire in ${days_left} days — regenerating"
      fi
    fi
  fi
}

check_existing

check_file() {
  if [[ -f "$1" && "$FORCE" != true ]]; then
    die "File exists: $1 (use -f to overwrite)"
  fi
}

# =============================================================================
# Step 1: Generate Intermediate CA
# =============================================================================
log "Generating Airgap Proxy Intermediate CA..."
log "Signed by: $(openssl x509 -in "$ROOT_CERT" -noout -subject | sed 's/subject=//')"
log "Validity: ${INTERMEDIATE_DAYS} days (~$((INTERMEDIATE_DAYS / 365)) years)"

# Generate RSA-4096 key for intermediate
openssl genrsa -out "$INTERMEDIATE_KEY" 4096 2>/dev/null
chmod 600 "$INTERMEDIATE_KEY"

# Create CSR
csr_file=$(mktemp)
openssl req -new \
  -key "$INTERMEDIATE_KEY" \
  -out "$csr_file" \
  -subj "/O=${ORG}/CN=${ORG} Airgap Proxy CA"

# Extensions for intermediate CA
ext_file=$(mktemp)
cat > "$ext_file" <<'EOF'
[v3_intermediate_ca]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

# Sign with root CA
openssl x509 -req \
  -in "$csr_file" \
  -CA "$ROOT_CERT" \
  -CAkey "$ROOT_KEY" \
  -CAcreateserial \
  -out "$INTERMEDIATE_CERT" \
  -days "$INTERMEDIATE_DAYS" \
  -sha256 \
  -extfile "$ext_file" \
  -extensions v3_intermediate_ca

rm -f "$csr_file" "$ext_file"

# Build chain: intermediate + root
cat "$INTERMEDIATE_CERT" "$ROOT_CERT" > "$CHAIN"

log "Intermediate CA: ${INTERMEDIATE_CERT}"
log "Chain (intermediate + root): ${CHAIN}"

# Verify intermediate
if openssl verify -CAfile "$ROOT_CERT" "$INTERMEDIATE_CERT" >/dev/null 2>&1; then
  log "Intermediate CA chain verification: PASSED"
else
  die "Intermediate CA chain verification: FAILED"
fi

# =============================================================================
# Step 2: Generate Leaf Certificate (ECDSA P-256, multi-SAN)
# =============================================================================
log ""
log "Generating leaf certificate with SANs: ${SANS[*]}"
log "Validity: ${LEAF_DAYS} days"

# Generate ECDSA P-256 key for leaf
openssl ecparam -name prime256v1 -genkey -noout -out "$LEAF_KEY" 2>/dev/null
chmod 600 "$LEAF_KEY"

# Build SAN extension
san_ext="subjectAltName = "
for i in "${!SANS[@]}"; do
  [[ $i -gt 0 ]] && san_ext+=","
  san_ext+="DNS:${SANS[$i]}"
done

# Create CSR for leaf
csr_file=$(mktemp)
openssl req -new \
  -key "$LEAF_KEY" \
  -out "$csr_file" \
  -subj "/O=${ORG}/CN=Airgap Proxy"

# Extensions for leaf
ext_file=$(mktemp)
cat > "$ext_file" <<EOF
[leaf]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
${san_ext}
EOF

# Sign with intermediate CA
openssl x509 -req \
  -in "$csr_file" \
  -CA "$INTERMEDIATE_CERT" \
  -CAkey "$INTERMEDIATE_KEY" \
  -CAcreateserial \
  -out "$LEAF_CERT" \
  -days "$LEAF_DAYS" \
  -sha256 \
  -extfile "$ext_file" \
  -extensions leaf

rm -f "$csr_file" "$ext_file"

# Build fullchain: leaf + intermediate + root
cat "$LEAF_CERT" "$INTERMEDIATE_CERT" "$ROOT_CERT" > "$LEAF_FULLCHAIN"

log "Leaf cert: ${LEAF_CERT}"
log "Leaf key: ${LEAF_KEY}"
log "Fullchain: ${LEAF_FULLCHAIN}"

# Verify leaf against chain
echo ""
if openssl verify -CAfile "$CHAIN" "$LEAF_CERT" >/dev/null 2>&1; then
  log "Leaf certificate chain verification: PASSED"
else
  die "Leaf certificate chain verification: FAILED"
fi

# Display certificate details
echo ""
log "=== Leaf Certificate Details ==="
openssl x509 -in "$LEAF_CERT" -noout -subject -issuer -dates
echo ""
log "SANs:"
openssl x509 -in "$LEAF_CERT" -noout -ext subjectAltName 2>/dev/null || \
  openssl x509 -in "$LEAF_CERT" -noout -text | grep -A1 "Subject Alternative Name"

echo ""
log "Certificate generation complete!"
log ""
log "Files:"
log "  ${INTERMEDIATE_CERT}     — Intermediate CA cert"
log "  ${INTERMEDIATE_KEY} — Intermediate CA key (KEEP SECRET)"
log "  ${CHAIN}              — CA chain (intermediate + root)"
log "  ${LEAF_CERT}             — Leaf server cert"
log "  ${LEAF_KEY}         — Leaf server key (KEEP SECRET)"
log "  ${LEAF_FULLCHAIN}   — Full chain for nginx (leaf + intermediate + root)"
