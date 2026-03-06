# Harvester Helm Harbor Sync

Nginx reverse proxy with automatic Helm chart synchronization to Harbor. Proxies upstream Helm HTTP repositories and automatically pushes downloaded charts to Harbor as OCI artifacts via a lightweight bash sidecar.

## Architecture

```
┌─────────────────┐     ┌──────────────────────────────────────────┐
│   Client         │     │  Proxy (docker-compose)                  │
│                 │     │                                          │
│ helm repo add   │────▶│  nginx:443                               │
│ helm pull       │     │    yum.$DOMAIN   → Rocky/RKE2 RPMs      │
│                 │     │    apt.$DOMAIN   → Debian/Ubuntu APT     │
│                 │     │    dl.$DOMAIN    → Cloud images          │
│                 │────▶│    charts.$DOMAIN → Helm repos           │
│                 │     │      └── mirror ──▶ helm-sync:8888       │
│                 │     │                      └── push to Harbor  │
│                 │     │    bin.$DOMAIN   → Static binaries       │
│                 │────▶│  registry:5000                           │
│                 │     │    Bootstrap container images             │
└─────────────────┘     └──────────────────────────────────────────┘
```

## How Helm Sync Works

1. User pulls a chart through the nginx proxy (e.g., `helm pull` via `charts.$DOMAIN`)
2. nginx serves the chart from upstream (with caching) and mirrors the request to the `helm-sync` sidecar
3. `helm-sync` detects `.tgz` chart downloads, looks up the chart in `charts.manifest`
4. If the chart doesn't exist in Harbor, it pulls from upstream and pushes as an OCI artifact
5. OCI-native charts (ghcr.io, docker.io, etc.) use Harbor's built-in proxy-cache — no sidecar needed

## Quick Start

```bash
# 1. Configure
cp .env.example .env
vi .env                            # Set your domain, Harbor creds, etc.

# 2. Generate secrets (optional — creates random Harbor password)
./scripts/generate-secrets.sh

# 3. Apply configuration to nginx configs
./scripts/configure.sh

# 4. Generate TLS certificates
./certs/generate-certs.sh --domain "$DOMAIN"

# 5. Start services
docker compose up -d

# 6. Verify
./test.sh
```

## Configuration

All settings are in `.env` (copy from `.env.example`):

| Variable | Description | Default |
|----------|-------------|---------|
| `DOMAIN` | Base domain for proxy hostnames | `example.com` |
| `HARBOR_HOST` | Harbor registry hostname | `harbor.example.com` |
| `HARBOR_USER` | Harbor robot account username | `robot$helm-sync` |
| `HARBOR_PASS` | Harbor robot account password | _(must be set)_ |
| `HARBOR_BACKEND` | Harbor HTTP backend for TLS termination | `harbor-backend` |
| `PKI_DIR` | Path to root CA for cert generation | `./pki` |
| `CERT_ORG` | Organization name for certificates | `Example Org` |

## Components

| Component | Purpose |
|-----------|---------|
| `nginx/` | Reverse proxy configs for 6 virtual hosts |
| `helm-sync/` | Sidecar that syncs HTTP Helm charts to Harbor as OCI |
| `helm-oci/charts.manifest` | Manifest of HTTP Helm charts to sync |
| `registry/` | Docker Distribution registry for bootstrap images |
| `certs/generate-certs.sh` | Intermediate CA + multi-SAN leaf cert generator |
| `bin/fetch-binaries.sh` | Pre-downloads GitHub release binaries |
| `terraform/` | Harvester VM provisioning (optional) |
| `scripts/configure.sh` | Applies `.env` settings to config files |
| `scripts/generate-secrets.sh` | Generates random credentials |

## Proxy Endpoints

| Hostname | Port | Backend |
|----------|------|---------|
| `yum.$DOMAIN` | 443 | Rocky 9/EPEL/RKE2 RPM repos |
| `apt.$DOMAIN` | 443 | Debian/Ubuntu APT repos |
| `dl.$DOMAIN` | 443 | Cloud images (qcow2) and ISOs |
| `charts.$DOMAIN` | 443 | 11 Helm HTTP chart repos |
| `bin.$DOMAIN` | 443 | Static binary files |
| `harbor.$DOMAIN` | 443 | Harbor TLS termination |
| `<proxy-ip>:5000` | 5000 | Bootstrap container registry |

## Harbor Robot Account Setup

Create a system-level robot account in Harbor with these permissions:
- **Project**: Create
- **Repository**: Push, Pull
- **Artifact**: Read, List
- **Tag**: Create, List

```bash
# Via Harbor API
curl -X POST "https://${HARBOR_HOST}/api/v2.0/robots" \
  -H "Content-Type: application/json" \
  -u "admin:${HARBOR_ADMIN_PASS}" \
  -d '{
    "name": "helm-sync",
    "level": "system",
    "permissions": [{
      "kind": "system",
      "namespace": "*",
      "access": [
        {"resource": "project", "action": "create"},
        {"resource": "repository", "action": "push"},
        {"resource": "repository", "action": "pull"},
        {"resource": "artifact", "action": "read"},
        {"resource": "artifact", "action": "list"},
        {"resource": "tag", "action": "create"},
        {"resource": "tag", "action": "list"}
      ]
    }]
  }'
```

## OCI Charts (Harbor Proxy-Cache)

OCI-native charts don't need the sidecar. Use Harbor's proxy-cache:

```bash
# Pull directly through Harbor's proxy-cache
helm pull oci://harbor.example.com/ghcr.io/argoproj/argo-helm/argo-cd --version 7.8.26
```

To add a new OCI registry, create a registry endpoint + proxy-cache project in Harbor.

## Caching

| Cache | Size | TTL | Eviction |
|-------|------|-----|----------|
| RPM/APT | 20 GB | 7 days | 30-day inactive |
| Helm charts | 2 GB | 1 day | 1-day inactive |
| Cloud images | 30 GB | 30 days | 30-day inactive |

## Certificate Chain

```
Root CA (offline)
└── Proxy Intermediate CA (5yr, pathlen:0)
    └── *.$DOMAIN leaf (1yr, ECDSA P-256)
        SANs: yum, apt, dl, charts, bin, harbor
```

## CI

GitHub Actions runs on every push/PR:
- **ShellCheck** — all `.sh` scripts
- **Hadolint** — Dockerfile linting
- **yamllint** — YAML validation
- **nginx -t** — config syntax check
- **docker compose config** — compose validation
- **Gitleaks** — secrets scanning

## License

MIT
