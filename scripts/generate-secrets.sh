#!/usr/bin/env bash
# Generate random secrets for .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found. Run: cp .env.example .env" >&2
    exit 1
fi

generate_password() {
    openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

HARBOR_PASS=$(generate_password)

echo ""
echo "Generated credentials:"
echo "  HARBOR_PASS=${HARBOR_PASS}"
echo ""

# Update .env file
if grep -q '^HARBOR_PASS=' "$ENV_FILE"; then
    sed -i "s|^HARBOR_PASS=.*|HARBOR_PASS=${HARBOR_PASS}|" "$ENV_FILE"
    echo "Updated HARBOR_PASS in ${ENV_FILE}"
else
    echo "HARBOR_PASS=${HARBOR_PASS}" >> "$ENV_FILE"
    echo "Added HARBOR_PASS to ${ENV_FILE}"
fi

echo ""
echo "IMPORTANT: Create a matching robot account in Harbor with this password."
echo "See README.md for instructions."
