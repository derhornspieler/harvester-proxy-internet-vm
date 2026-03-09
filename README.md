# Harvester Helm Harbor Sync

[![CI](https://github.com/derhornspieler/harvester-helm-harbor-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/derhornspieler/harvester-helm-harbor-sync/actions/workflows/ci.yml)

Nginx reverse proxy with automatic Helm chart synchronization to Harbor. Proxies upstream Helm HTTP repositories and automatically pushes downloaded charts to Harbor as OCI artifacts via a lightweight bash sidecar. Designed for air-gapped and semi-connected Kubernetes environments running on Harvester.

## Architecture

```mermaid
graph LR
    subgraph Clients
        C1[helm pull / repo add]
        C2[yum install / apt-get]
        C3[curl / wget]
        C4[go build / npm install<br/>pip install / cargo build]
    end

    subgraph Proxy["Proxy (VM or K8s Pod)"]
        direction TB
        NG[nginx<br/>caching reverse proxy]
        HS[helm-sync sidecar<br/>ncat :8888]
        REG[registry:5000<br/>bootstrap images]
    end

    subgraph Upstream["Internet (Upstream)"]
        HR[Helm HTTP Repos<br/>jetstack, hashicorp, ...]
        RPM[RPM / APT Repos<br/>Rocky, EPEL, Debian]
        DL[Cloud Images<br/>qcow2, ISOs]
        PKG[Language Registries<br/>Go, npm, PyPI, Maven, crates.io]
    end

    subgraph Harbor["Harbor (External or Co-located)"]
        OCI[OCI Artifact Storage<br/>charts.jetstack.io/cert-manager]
        PC[Proxy-Cache<br/>ghcr.io, docker.io, ...]
    end

    C1 & C2 & C3 & C4 -->|HTTPS| NG
    NG -->|proxy_pass| HR & RPM & DL & PKG
    NG -.->|mirror<br/>fire-and-forget| HS
    HS -->|helm push<br/>OCI artifact| OCI
    C1 -->|helm pull oci://| PC

    style NG fill:#2d6a4f,color:#fff
    style HS fill:#264653,color:#fff
    style OCI fill:#e76f51,color:#fff
    style PC fill:#e76f51,color:#fff
```

> **Harbor** can be **external** (separate infrastructure) or **co-located** (installed on the same VM using Harbor's official installer, with nginx providing TLS termination).

### VM Deployment — External Harbor

```mermaid
graph TB
    subgraph VM["Proxy VM"]
        subgraph DC["docker-compose"]
            N443["nginx :443<br/>TLS termination + caching"]
            HSC["helm-sync :8888<br/>ncat listener"]
            R5000["registry :5000<br/>Docker Distribution v2"]
            SQ["squid :3128<br/>forward HTTP/HTTPS proxy"]
        end
        CERTS["TLS certs<br/>*.DOMAIN leaf"]
        CACHE["Docker volumes<br/>rpm, charts, downloads,<br/>go, npm, pypi, maven, crates"]
    end

    N443 ---|docker DNS| HSC
    N443 --- CERTS
    N443 --- CACHE

    EXT_HARBOR["Harbor (external)"]
    HSC -->|helm push| EXT_HARBOR

    style N443 fill:#2d6a4f,color:#fff
    style HSC fill:#264653,color:#fff
    style SQ fill:#457b9d,color:#fff
    style EXT_HARBOR fill:#e76f51,color:#fff
```

### VM Deployment — Co-located Harbor

```mermaid
graph TB
    subgraph VM["Proxy VM"]
        subgraph DC["docker-compose (proxy stack)"]
            N443["nginx :443<br/>TLS termination + caching"]
            HSC["helm-sync :8888<br/>ncat listener"]
            R5000["registry :5000<br/>Docker Distribution v2"]
        end

        subgraph HarborStack["Harbor (official installer)"]
            HCORE["harbor-core :8080"]
            HDB["PostgreSQL"]
            HREDIS["Redis"]
            HREG["Harbor Registry"]
            HTRIVY["Trivy Scanner"]
        end

        CERTS["TLS certs<br/>*.DOMAIN + harbor.DOMAIN"]
        CACHE["Docker volumes<br/>rpm, charts, downloads"]
    end

    N443 ---|docker DNS| HSC
    N443 ---|"harbor.DOMAIN<br/>proxy_pass :8080"| HCORE
    N443 --- CERTS
    N443 --- CACHE
    HCORE --- HDB & HREDIS & HREG
    HSC -->|helm push<br/>via nginx| N443

    style N443 fill:#2d6a4f,color:#fff
    style HSC fill:#264653,color:#fff
    style HCORE fill:#e76f51,color:#fff
    style HREG fill:#e76f51,color:#fff
```

> **Co-located mode**: Harbor's official installer runs its own docker-compose stack on the same VM. nginx provides TLS termination at `harbor.$DOMAIN` and proxies to Harbor's HTTP port 8080. Run `./scripts/install-harbor.sh` to set this up.

### Kubernetes Deployment (Helm chart)

```mermaid
graph TB
    subgraph K8s["Kubernetes Cluster"]
        ING["Ingress Controller<br/>TLS termination"]
        subgraph Pod["Proxy Pod (sidecar pattern)"]
            N8080["nginx :8080<br/>HTTP only, caching"]
            HS8888["helm-sync :8888<br/>localhost sidecar"]
        end
        SVC["Service :80"]
        PVC["PVCs<br/>rpm, charts, downloads"]
        CM["ConfigMaps<br/>nginx configs, manifest"]
        SEC["Secret<br/>Harbor credentials"]

        subgraph RegPod["Registry Pod (optional)"]
            R5000K["registry :5000"]
        end
        RPVC["PVC<br/>registry-data"]
    end

    ING -->|*.DOMAIN| SVC
    SVC --> N8080
    N8080 ---|localhost| HS8888
    N8080 --- PVC
    N8080 --- CM
    HS8888 --- SEC
    HS8888 --- CM
    R5000K --- RPVC

    HARBOR["Harbor<br/>(external or in-cluster)"]
    HS8888 -->|helm push| HARBOR

    style ING fill:#457b9d,color:#fff
    style N8080 fill:#2d6a4f,color:#fff
    style HS8888 fill:#264653,color:#fff
    style HARBOR fill:#e76f51,color:#fff
```

## How It Works

### Helm Chart Sync Flow

```mermaid
sequenceDiagram
    participant User
    participant Proxy as nginx (proxy)
    participant Upstream as Upstream Helm Repo
    participant Sidecar as helm-sync (sidecar)
    participant Harbor as Harbor (external)

    User->>Proxy: GET /jetstack/cert-manager-v1.19.3.tgz
    activate Proxy
    Proxy->>Upstream: proxy_pass → charts.jetstack.io
    Upstream-->>Proxy: chart .tgz (cached 1 day)
    Proxy-->>User: chart .tgz

    Note over Proxy,Sidecar: nginx mirror — fire-and-forget (1s timeout)
    Proxy--)Sidecar: /sync + X-Original-URI header
    deactivate Proxy

    activate Sidecar
    Sidecar->>Sidecar: Parse filename → cert-manager + v1.19.3
    Sidecar->>Sidecar: Lookup in charts.manifest
    Sidecar->>Harbor: GET /api/v2.0/.../artifacts (exists?)
    alt Not in Harbor
        Sidecar->>Harbor: Create project charts.jetstack.io
        Sidecar->>Upstream: helm pull cert-manager v1.19.3
        Sidecar->>Harbor: helm push → OCI artifact
        Note over Harbor: oci://harbor/charts.jetstack.io/cert-manager:v1.19.3
    else Already exists
        Sidecar->>Sidecar: Skip (already synced)
    end
    deactivate Sidecar
```

### Two Paths for Helm Charts

```mermaid
flowchart TD
    A["Need a Helm chart"] --> B{"What type of<br/>chart repo?"}

    B -->|"HTTP repo<br/>(jetstack, hashicorp, ...)"| C["Pull through nginx proxy"]
    C --> D["charts.DOMAIN/jetstack/cert-manager-v1.19.3.tgz"]
    D --> E["nginx caches response<br/>+ mirrors request to sidecar"]
    E --> F["helm-sync checks Harbor<br/>pulls + pushes if missing"]
    F --> G["Available as OCI artifact<br/>oci://harbor/PROJECT/CHART:VERSION"]

    B -->|"OCI registry<br/>(ghcr.io, docker.io, ...)"| H["Pull through Harbor proxy-cache"]
    H --> I["helm pull oci://harbor/ghcr.io/.../argo-cd"]
    I --> J["Harbor proxies + caches<br/>from upstream OCI registry"]
    J --> G

    style C fill:#2d6a4f,color:#fff
    style H fill:#264653,color:#fff
    style G fill:#e76f51,color:#fff
    style E fill:#2d6a4f,color:#fff
    style F fill:#264653,color:#fff
    style J fill:#e76f51,color:#fff
```

### Request Lifecycle (nginx mirror detail)

```mermaid
flowchart LR
    A["Client<br/>helm pull"] --> B["nginx<br/>location /jetstack/"]

    B --> C["proxy_pass<br/>charts.jetstack.io"]
    C --> D["Upstream responds<br/>with .tgz"]
    D --> E["Client receives<br/>chart (cached)"]

    B -.-> F["mirror /mirror-sync<br/>(async, non-blocking)"]
    F -.-> G["internal location<br/>proxy_pass localhost:8888"]
    G -.-> H["helm-sync /sync<br/>handler"]
    H -.-> I["Background:<br/>check + push to Harbor"]

    style F fill:#ffa,stroke:#333,color:#333
    style G fill:#ffa,stroke:#333,color:#333
    style H fill:#264653,color:#fff
    style I fill:#e76f51,color:#fff
```

## Prerequisites

- **Docker** with Compose plugin (v2)
- **openssl** for certificate generation
- **Harbor** instance — either:
  - **External**: existing Harbor on separate infrastructure, or
  - **Co-located**: installed on the same VM via `./scripts/install-harbor.sh`
- A **root CA** certificate and key (for generating the proxy's intermediate CA)
- DNS or `/etc/hosts` entries pointing `*.$DOMAIN` to the proxy VM

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/derhornspieler/harvester-helm-harbor-sync.git
cd harvester-helm-harbor-sync
cp .env.example .env
vi .env                            # Set your domain, Harbor creds, etc.

# 2. Generate random Harbor password (optional)
./scripts/generate-secrets.sh

# 3. Apply domain to nginx configs
./scripts/configure.sh

# 4. Generate TLS certificates
./certs/generate-certs.sh --domain "$(grep DOMAIN .env | cut -d= -f2)"

# 5. Add /etc/hosts entries (or configure DNS)
DOMAIN=$(grep DOMAIN .env | cut -d= -f2)
echo "127.0.0.1  yum.${DOMAIN} apt.${DOMAIN} dl.${DOMAIN} charts.${DOMAIN} bin.${DOMAIN} harbor.${DOMAIN}" \
  | sudo tee -a /etc/hosts

# 6. Trust the CA
sudo cp certs/ca-chain.pem /etc/pki/ca-trust/source/anchors/proxy-ca.pem
sudo update-ca-trust

# 7. Start services
docker compose up -d

# 8. Verify
./test.sh
```

## Deployment Options

### Option A: Docker Compose (VM)

Deploy to a dedicated VM via SSH or Terraform:

```bash
# Via SSH
./setup-proxy-vm.sh <proxy-vm-ip> --domain yourdomain.com --ssh-user rocky

# Or via Terraform on Harvester
cd terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
terraform init && terraform apply
```

#### Co-located Harbor (Optional)

If you don't have an external Harbor instance, install one on the same VM:

```bash
# Install Harbor (downloads official offline installer)
./scripts/install-harbor.sh

# Set HARBOR_HOST to the local Harbor
sed -i 's/^HARBOR_HOST=.*/HARBOR_HOST=harbor.yourdomain.com/' .env

# Reconfigure and restart
./scripts/configure.sh
docker compose restart nginx
```

Harbor runs its own docker-compose stack on port 8080. nginx proxies `harbor.$DOMAIN` with TLS termination. The `harbor.conf` vhost is included by default — if Harbor isn't running, it simply returns 502 on that vhost (other vhosts are unaffected).

### Option B: Kubernetes (Helm Chart)

Deploy directly to a Kubernetes cluster. nginx runs behind an Ingress controller, with helm-sync as a sidecar container in the same pod.

```bash
# Install with custom values
helm install proxy ./chart \
  --namespace proxy-cache --create-namespace \
  --set domain=yourdomain.com \
  --set harbor.host=harbor.yourdomain.com \
  --set harbor.user='robot$helm-sync' \
  --set harbor.pass=YOUR_PASSWORD \
  --set proxy.image.helmSync.repository=your-registry/helm-sync \
  --set ingress.className=nginx \
  --set ingress.tls.secretName=proxy-tls-cert

# Or use a values file
helm install proxy ./chart \
  --namespace proxy-cache --create-namespace \
  -f my-values.yaml
```

**Prerequisites for Helm deployment:**
- A Kubernetes Ingress controller (e.g., ingress-nginx)
- A TLS Secret for `*.yourdomain.com` (or individual SANs)
- The `helm-sync` container image built and pushed to an accessible registry
- DNS or wildcard DNS pointing `*.yourdomain.com` to the Ingress

**Build the helm-sync image:**

```bash
docker build -t your-registry/helm-sync:latest ./helm-sync
docker push your-registry/helm-sync:latest
```

**Key differences from VM deployment:**
- TLS is handled by the Ingress controller, not nginx
- nginx listens on HTTP (:8080) internally
- helm-sync is a sidecar in the nginx pod (communicates via `localhost:8888`)
- Chart repos are configured in `values.yaml` — adding a new repo is a `helm upgrade`
- Cache volumes use Kubernetes PVCs

## Configuration

All settings live in `.env` (copy from `.env.example`):

| Variable | Description | Default |
|----------|-------------|---------|
| `DOMAIN` | Base domain for all proxy hostnames | `example.com` |
| `HARBOR_HOST` | External Harbor registry hostname | `harbor.example.com` |
| `HARBOR_USER` | Harbor robot account username | `robot$helm-sync` |
| `HARBOR_PASS` | Harbor robot account password | _(required)_ |
| `PROXY_VM_IP` | Static IP for the proxy VM | `10.0.0.100` |
| `SSH_USER` | SSH user for VM provisioning | `rocky` |
| `PKI_DIR` | Path to root CA cert/key directory | `./pki` |
| `CERT_ORG` | Organization name for generated certificates | `Example Org` |

After changing `.env`, run `./scripts/configure.sh` to apply the domain to nginx configs.

## Directory Structure

```
.
├── .env.example                    # Configuration template
├── .github/workflows/ci.yml       # GitHub Actions CI pipeline
├── docker-compose.yaml             # Service definitions (nginx, helm-sync, registry)
├── README.md
│
├── nginx/                          # Reverse proxy configuration
│   ├── nginx.conf                  # Main config (resolver, log format, health check)
│   ├── conf.d/
│   │   ├── yum.conf                # Rocky Linux / EPEL / RKE2 RPM repos
│   │   ├── apt.conf                # Debian / Ubuntu APT repos
│   │   ├── dl.conf                 # Cloud images (qcow2, ISOs)
│   │   ├── charts.conf             # 11 Helm HTTP chart repos (with mirror)
│   │   ├── bin.conf                # Static binary files
│   │   └── harbor.conf             # Co-located Harbor reverse proxy (optional)
│   └── includes/
│       ├── ssl-defaults.conf       # Shared TLS settings
│       ├── proxy-defaults.conf     # Shared proxy headers/timeouts
│       └── cache.conf              # Cache path declarations
│
├── helm-sync/                      # Helm-to-Harbor sync sidecar
│   ├── Dockerfile                  # Alpine + bash + helm + ncat
│   ├── entrypoint.sh               # CA cert installer
│   └── helm-sync.sh                # HTTP listener + sync logic
│
├── helm-oci/
│   ├── charts.manifest             # HTTP chart definitions (pipe-delimited)
│   └── sync-helm-oci.sh            # Batch sync script (manual/one-time)
│
├── registry/
│   ├── config.yml                  # Docker Distribution v2 config
│   └── populate-bootstrap-registry.sh
│
├── certs/
│   └── generate-certs.sh           # Intermediate CA + multi-SAN leaf cert
│
├── bin/
│   └── fetch-binaries.sh           # Pre-download GitHub release binaries
│
├── scripts/
│   ├── configure.sh                # Apply .env settings to config files
│   ├── generate-secrets.sh         # Generate random credentials
│   └── install-harbor.sh           # Install co-located Harbor (optional)
│
├── terraform/                      # Harvester VM provisioning (optional)
│   ├── main.tf                     # Cloud-init + VM resource
│   ├── variables.tf                # Input variables
│   ├── outputs.tf                  # VM IP, hostnames, /etc/hosts entry
│   ├── versions.tf                 # Provider requirements
│   ├── providers.tf                # Harvester provider config
│   └── fetch-providers.sh          # Download providers for offline use
│
├── squid/
│   └── squid.conf                  # Squid forward HTTP/HTTPS proxy config
│
├── env/
│   └── airgap.env.example          # Full .env template for AIRGAPPED=true deployments
│
├── setup-proxy-vm.sh               # Provision remote VM via SSH
└── test.sh                         # End-to-end verification (30 tests)
```

## Components

### nginx (Reverse Proxy)

Twelve virtual hosts behind TLS, all sharing the same multi-SAN certificate:

| Virtual Host | Upstream | Cache |
|-------------|----------|-------|
| `yum.$DOMAIN` | Rocky 9 BaseOS/AppStream/CRB, EPEL 9, RKE2 RPMs | 20 GB, 7-day TTL |
| `apt.$DOMAIN` | Debian bookworm, Ubuntu noble + security repos | 20 GB, 7-day TTL |
| `dl.$DOMAIN` | Rocky 9 cloud images (qcow2) | 30 GB, 30-day TTL |
| `charts.$DOMAIN` | 11 Helm HTTP chart repos (see below) | 2 GB, 1-day TTL |
| `bin.$DOMAIN` | Pre-downloaded GitHub release binaries (static) | Client-side only |
| `harbor.$DOMAIN` | Co-located Harbor instance (localhost:8080) | — (pass-through) |
| `go.$DOMAIN` | proxy.golang.org + sum.golang.org | 5 GB, 30-day TTL |
| `npm.$DOMAIN` | registry.npmjs.org | 10 GB, 30-day TTL |
| `pypi.$DOMAIN` | pypi.org + files.pythonhosted.org | 10 GB, 30-day TTL |
| `maven.$DOMAIN` | repo1.maven.org + maven.google.com + plugins.gradle.org | 10 GB, 30-day TTL |
| `crates.$DOMAIN` | crates.io sparse index + static.crates.io | 5 GB, 30-day TTL |

### helm-sync (Sidecar)

Lightweight bash HTTP server using `ncat`. Listens on port 8888.

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/sync` | GET | Called by nginx mirror — parses `X-Original-URI`, syncs to Harbor |
| `/sync-all` | GET | Trigger full sync of all charts in manifest |
| `/healthz` | GET | Health check |

**How the mirror works:**
- Each `charts.conf` location block has `mirror /mirror-sync; mirror_request_body off;`
- `/mirror-sync` is an `internal` location that proxies to `helm-sync:8888/sync`
- Timeouts are 1s — nginx never blocks waiting for the sidecar
- The sidecar runs `sync_chart()` in the background (`&`) so ncat can accept the next connection

### Language Package Proxies

Caching reverse proxies for language-specific package registries. Configure your build tools to use these instead of public registries.

| Language | Virtual Host | Usage |
|----------|-------------|-------|
| Go | `go.$DOMAIN` | `GOPROXY=https://go.$DOMAIN,direct` |
| Node.js | `npm.$DOMAIN` | `npm config set registry https://npm.$DOMAIN/` |
| Python | `pypi.$DOMAIN` | `pip install --index-url https://pypi.$DOMAIN/simple/` |
| Java | `maven.$DOMAIN` | `<mirror><url>https://maven.$DOMAIN/maven2/</url></mirror>` |
| Rust | `crates.$DOMAIN` | `[source.internal] registry = "sparse+https://crates.$DOMAIN/api/v1/crates/"` |

### Squid Forward Proxy

Generic HTTP/HTTPS forward proxy for workloads that need direct internet access. Runs on port 3128, supports `CONNECT` tunneling for HTTPS.

```bash
# Usage
export HTTP_PROXY=http://proxy.$DOMAIN:3128
export HTTPS_PROXY=http://proxy.$DOMAIN:3128
export NO_PROXY=localhost,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.$DOMAIN,.svc,.cluster.local
```

Access is restricted to RFC 1918 private networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).

### Proxied Helm Chart Repos

| Location Path | Upstream | Chart |
|--------------|----------|-------|
| `/jetstack/` | charts.jetstack.io | cert-manager |
| `/cnpg/` | cloudnative-pg.github.io/charts | cloudnative-pg |
| `/hashicorp/` | helm.releases.hashicorp.com | vault |
| `/goharbor/` | helm.goharbor.io | harbor |
| `/prometheus-community/` | prometheus-community.github.io/helm-charts | kube-prometheus-stack |
| `/external-secrets/` | external-secrets.io | external-secrets |
| `/autoscaler/` | kubernetes.github.io/autoscaler | cluster-autoscaler |
| `/ot-helm/` | ot-container-kit.github.io/helm-charts | redis-operator |
| `/kasmtech/` | helm.kasmweb.com | kasm |
| `/gitlab/` | charts.gitlab.io | gitlab-runner |
| `/mariadb-operator/` | mariadb-operator.github.io/mariadb-operator | mariadb-operator |

## Adding a New HTTP Helm Chart

1. **Add to `helm-oci/charts.manifest`:**

   ```
   http|https://new-repo.example.io|1.2.3|new-repo.example.io|chart-name|HELM_OCI_CHART_NAME
   ```

   Format: `TYPE|SOURCE|VERSION|HARBOR_PROJECT|CHART_NAME|ENV_VAR`

2. **Add nginx location block** in `nginx/conf.d/charts.conf`:

   ```nginx
   # chart-name
   location /new-repo/ {
       mirror /mirror-sync;
       mirror_request_body off;
       proxy_pass https://new-repo.example.io/;
       include /etc/nginx/includes/proxy-defaults.conf;
       proxy_cache charts_cache;
       proxy_cache_valid 200 1d;
       proxy_cache_valid 404 1m;
       proxy_cache_use_stale error timeout updating;
       add_header X-Cache-Status $upstream_cache_status;
   }
   ```

3. **Restart nginx:**

   ```bash
   docker compose restart nginx
   ```

4. **Test:**

   ```bash
   helm repo add new-repo https://charts.$DOMAIN/new-repo
   helm pull new-repo/chart-name --version 1.2.3
   ```

   The sidecar will automatically push it to Harbor as `oci://$HARBOR_HOST/new-repo.example.io/chart-name:1.2.3`.

## Adding a New OCI Registry (Harbor Proxy-Cache)

OCI-native charts (ghcr.io, docker.io, quay.io, etc.) don't need the sidecar. Harbor's built-in proxy-cache handles them natively.

1. **Create a registry endpoint in Harbor:**

   ```bash
   curl -X POST "https://${HARBOR_HOST}/api/v2.0/registries" \
     -H "Content-Type: application/json" \
     -u "admin:${HARBOR_ADMIN_PASS}" \
     -d '{
       "name": "new-registry.io",
       "type": "docker-registry",
       "url": "https://new-registry.io"
     }'
   ```

2. **Create a proxy-cache project:**

   ```bash
   # Get the registry ID from step 1
   REGISTRY_ID=$(curl -s "https://${HARBOR_HOST}/api/v2.0/registries" \
     -u "admin:${HARBOR_ADMIN_PASS}" | jq '.[] | select(.name=="new-registry.io") | .id')

   curl -X POST "https://${HARBOR_HOST}/api/v2.0/projects" \
     -H "Content-Type: application/json" \
     -u "admin:${HARBOR_ADMIN_PASS}" \
     -d "{
       \"project_name\": \"new-registry.io\",
       \"public\": true,
       \"registry_id\": ${REGISTRY_ID}
     }"
   ```

3. **Pull charts through Harbor:**

   ```bash
   helm pull oci://${HARBOR_HOST}/new-registry.io/org/chart-name --version 1.0.0
   ```

**Common registries already configured as proxy-cache in most Harbor instances:**
`ghcr.io`, `docker.io`, `gcr.io`, `quay.io`, `registry.k8s.io`, `public.ecr.aws`

## Harbor Robot Account Setup

The helm-sync sidecar needs a Harbor robot account with permissions to create projects and push charts.

```bash
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

Save the returned `secret` as `HARBOR_PASS` in your `.env`. The username will be `robot$helm-sync`.

## Certificate Chain

```
Root CA (offline, long-lived)
└── Proxy Intermediate CA (5yr, RSA-4096, pathlen:0)
    └── *.$DOMAIN leaf (1yr, ECDSA P-256)
        SANs: yum, apt, dl, charts, bin, harbor, go, npm, pypi, maven, crates, proxy
```

The CA chain (`certs/ca-chain.pem`) must be trusted by all clients. For Kubernetes nodes, inject it via cloud-init or distribute it as part of your node provisioning.

```bash
# Generate certificates
./certs/generate-certs.sh --pki-dir /path/to/pki --domain yourdomain.com

# Trust on RHEL/Rocky
sudo cp certs/ca-chain.pem /etc/pki/ca-trust/source/anchors/proxy-ca.pem
sudo update-ca-trust

# Trust on Debian/Ubuntu
sudo cp certs/ca-chain.pem /usr/local/share/ca-certificates/proxy-ca.crt
sudo update-ca-certificates
```

## Caching

All caches use named Docker volumes for persistence across container restarts.

| Cache | Size Limit | TTL | Inactive Eviction | Volume |
|-------|-----------|-----|-------------------|--------|
| RPM/APT | 20 GB | 7 days | 30 days | `nginx-cache-rpm` |
| Helm charts | 2 GB | 1 day | 1 day | `nginx-cache-charts` |
| Cloud images | 30 GB | 30 days | 30 days | `nginx-cache-downloads` |
| Go modules | 5 GB | 7 days | 30 days | `nginx-cache-go` |
| npm packages | 10 GB | 7 days | 30 days | `nginx-cache-npm` |
| PyPI packages | 10 GB | 1/30 days | 30 days | `nginx-cache-pypi` |
| Maven artifacts | 10 GB | 30 days | 30 days | `nginx-cache-maven` |
| Rust crates | 5 GB | 1/30 days | 30 days | `nginx-cache-crates` |
| Squid forward proxy | 10 GB | — | — | `squid-cache` |
| Container images | Unlimited | — | — | `registry-data` |

## Troubleshooting

### helm-sync not pushing to Harbor

Check the sidecar logs:

```bash
docker exec helm-sync cat /var/log/helm-sync/sync.log
```

Common issues:
- **`HARBOR_HOST must be set`** — Missing `.env` or env vars not loaded
- **`Harbor registry login failed`** — Wrong credentials or Harbor unreachable
- **`Chart not in manifest`** — Chart name doesn't match any entry in `charts.manifest`
- **`Failed to pull`** — Upstream repo unreachable or chart version doesn't exist

### nginx returns 502/504 for chart repos

```bash
# Check nginx can resolve upstream hostnames
docker exec airgap-nginx nslookup charts.jetstack.io

# Check nginx error logs
docker logs airgap-nginx --tail 50
```

### Trigger a full sync manually

```bash
curl http://localhost:8888/sync-all
# Or from outside the container:
docker exec helm-sync wget -qO- http://127.0.0.1:8888/sync-all
```

### Verify a chart exists in Harbor

```bash
curl -s "https://${HARBOR_HOST}/api/v2.0/projects/charts.jetstack.io/repositories/cert-manager/artifacts" \
  -u "${HARBOR_USER}:${HARBOR_PASS}" | jq '.[].tags[].name'
```

### Clear nginx cache

```bash
docker compose down
docker volume rm harvester-helm-harbor-sync_nginx-cache-charts
docker compose up -d
```

## CI

GitHub Actions runs on every push and pull request:

| Job | Tool | What it checks |
|-----|------|---------------|
| `lint` | ShellCheck | All `.sh` scripts for bugs and portability |
| `lint` | Hadolint | Dockerfile best practices |
| `lint` | yamllint | YAML syntax (docker-compose, registry config) |
| `nginx-config` | `nginx -t` | nginx configuration syntax |
| `docker-compose` | `docker compose config` | Compose file validity |
| `secrets-scan` | Gitleaks | No secrets in commit history |

## License

MIT
