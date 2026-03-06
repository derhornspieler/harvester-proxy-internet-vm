#!/usr/bin/env bash
set -euo pipefail

# Install custom CA if mounted (Alpine uses /usr/local/share/ca-certificates/)
if [[ -f /etc/ssl/custom/ca-chain.pem ]]; then
    mkdir -p /usr/local/share/ca-certificates
    cp /etc/ssl/custom/ca-chain.pem /usr/local/share/ca-certificates/airgap-ca.crt
    update-ca-certificates 2>/dev/null
fi

exec /opt/helm-sync/helm-sync.sh "$@"
