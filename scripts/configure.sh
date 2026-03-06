#!/usr/bin/env bash
# Apply domain from .env to nginx configuration files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found. Run: cp .env.example .env" >&2
    exit 1
fi

# Source .env
set -a
source "$ENV_FILE"
set +a

DOMAIN="${DOMAIN:-example.com}"
HARBOR_HOST="${HARBOR_HOST:-harbor.example.com}"

echo "Configuring for domain: ${DOMAIN}"
echo "Harbor host: ${HARBOR_HOST}"
echo ""

# Replace domain in nginx configs
find "${PROJECT_DIR}/nginx" -name '*.conf' -exec \
    sed -i "s/example\.com/${DOMAIN}/g" {} +

# Replace harbor host in harbor.conf if HARBOR_HOST differs from default
if [[ -f "${PROJECT_DIR}/nginx/conf.d/harbor.conf" && "$HARBOR_HOST" != "harbor.${DOMAIN}" ]]; then
    sed -i "s/harbor\.${DOMAIN}/${HARBOR_HOST}/g" "${PROJECT_DIR}/nginx/conf.d/harbor.conf"
fi

# Replace domain in helm manifest
sed -i "s/charts\.example\.com/charts.${DOMAIN}/g" \
    "${PROJECT_DIR}/helm-oci/charts.manifest"

# Replace harbor host in env example
sed -i "s/harbor\.example\.com/${HARBOR_HOST}/g" \
    "${PROJECT_DIR}/env/airgap.env.example"

# Replace domain in env example
sed -i "s/example\.com/${DOMAIN}/g" \
    "${PROJECT_DIR}/env/airgap.env.example"

echo "Configuration applied. Review changes with: git diff"
