# Airgap Proxy Services — Developer Reference

## Proxy VM: 172.16.3.200
All services terminate TLS via self-signed certs (CA: `certs/ca-chain.pem`).

---

## Reverse Proxies (nginx on :443)

### Package Repositories

| Service | URL | Upstream | Usage |
|---------|-----|----------|-------|
| **YUM/RPM** | `https://yum.aegisgroup.ch` | Rocky 9, EPEL 9, RKE2 | `baseurl=https://yum.aegisgroup.ch/rocky/9/BaseOS/x86_64/os/` |
| **APT** | `https://apt.aegisgroup.ch` | Debian, Ubuntu | `deb https://apt.aegisgroup.ch/debian/ bookworm main` |
| **APK** | `https://apk.aegisgroup.ch` | Alpine v3.20, v3.21, edge | `https://apk.aegisgroup.ch/alpine/v3.21/main` |

### Language Package Managers

| Service | URL | Upstream | Usage |
|---------|-----|----------|-------|
| **Go** | `https://go.aegisgroup.ch` | proxy.golang.org, sum.golang.org | `GOPROXY=https://go.aegisgroup.ch,direct` |
| **NPM** | `https://npm.aegisgroup.ch` | registry.npmjs.org | `npm config set registry https://npm.aegisgroup.ch/` |
| **PyPI** | `https://pypi.aegisgroup.ch` | pypi.org, files.pythonhosted.org | `pip install --index-url https://pypi.aegisgroup.ch/simple/` |
| **Maven** | `https://maven.aegisgroup.ch` | repo1.maven.org, maven.google.com, plugins.gradle.org | `<url>https://maven.aegisgroup.ch/maven2/</url>` |
| **Crates** | `https://crates.aegisgroup.ch` | index.crates.io, static.crates.io | `[source.internal] registry = "sparse+https://crates.aegisgroup.ch/api/v1/crates/"` |

### Helm Charts

| Service | URL | Upstream | Usage |
|---------|-----|----------|-------|
| **Helm** | `https://charts.aegisgroup.ch` | 11 chart repos | `helm repo add jetstack https://charts.aegisgroup.ch/jetstack/` |

Available chart prefixes: `/jetstack/`, `/cnpg/`, `/hashicorp/`, `/goharbor/`, `/prometheus-community/`, `/external-secrets/`, `/autoscaler/`, `/ot-helm/`, `/kasmtech/`, `/gitlab/`, `/mariadb-operator/`

### Cloud Images & Downloads

| Service | URL | Upstream | Usage |
|---------|-----|----------|-------|
| **Downloads** | `https://dl.aegisgroup.ch` | Rocky, Debian, Ubuntu cloud images | See paths below |

| Path | Content |
|------|---------|
| `/rocky/9/images/x86_64/` | Rocky 9 qcow2, ISOs |
| `/debian/bookworm/latest/` | Debian 12 qcow2 + SHA512SUMS |
| `/ubuntu/noble/current/` | Ubuntu 24.04 img + SHA256SUMS |

---

## Forward Proxy (Squid on :3128)

For generic internet access from CI pipelines, pods, or VMs:

```yaml
env:
  - name: http_proxy
    value: "http://proxy.aegisgroup.ch:3128"
  - name: https_proxy
    value: "http://proxy.aegisgroup.ch:3128"
  - name: no_proxy
    value: "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.aegisgroup.ch"
```

Shell usage:
```bash
export http_proxy=http://proxy.aegisgroup.ch:3128
export https_proxy=http://proxy.aegisgroup.ch:3128
export no_proxy="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.aegisgroup.ch"
```

---

## Harbor Registry

| Service | URL | Purpose |
|---------|-----|---------|
| **Harbor UI** | `https://harbor.aegisgroup.ch` | Web UI |
| **Harbor v2 API** | `https://harbor.aegisgroup.ch/v2/` | Docker registry API |
| **Bootstrap Registry** | `172.16.3.200:5000` | Standalone Docker registry |

### Proxy-Cache Projects (pull-through cache for container images)

Pull images through Harbor instead of going direct to public registries:

```bash
# Instead of:                         Use:
docker pull nginx:latest             # harbor.aegisgroup.ch/docker.io/library/nginx:latest
docker pull ghcr.io/org/img:tag      # harbor.aegisgroup.ch/ghcr.io/org/img:tag
docker pull quay.io/org/img:tag      # harbor.aegisgroup.ch/quay.io/org/img:tag
docker pull registry.k8s.io/img:tag  # harbor.aegisgroup.ch/registry.k8s.io/img:tag
```

Available proxy-cache registries: `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, `gcr.io`, `public.ecr.aws`, `docker.elastic.co`, `registry.gitlab.com`

### Helm OCI Charts

helm-sync automatically pushes HTTP Helm charts to Harbor as OCI artifacts when pulled through `charts.aegisgroup.ch`. Charts are stored at:

```
harbor.aegisgroup.ch/<source-fqdn>/<chart-name>:<version>
```

Example: `harbor.aegisgroup.ch/charts.jetstack.io/cert-manager:v1.19.3`

---

## DNS Requirements

All proxy hostnames must resolve to `172.16.3.200`:

```
yum.aegisgroup.ch      → 172.16.3.200
apt.aegisgroup.ch      → 172.16.3.200
apk.aegisgroup.ch      → 172.16.3.200
dl.aegisgroup.ch       → 172.16.3.200
charts.aegisgroup.ch   → 172.16.3.200
go.aegisgroup.ch       → 172.16.3.200
npm.aegisgroup.ch      → 172.16.3.200
pypi.aegisgroup.ch     → 172.16.3.200
maven.aegisgroup.ch    → 172.16.3.200
crates.aegisgroup.ch   → 172.16.3.200
harbor.aegisgroup.ch   → 172.16.3.200
proxy.aegisgroup.ch    → 172.16.3.200
bin.aegisgroup.ch      → 172.16.3.200
```

Or add to `/etc/hosts`:
```
172.16.3.200  yum.aegisgroup.ch apt.aegisgroup.ch apk.aegisgroup.ch dl.aegisgroup.ch charts.aegisgroup.ch bin.aegisgroup.ch go.aegisgroup.ch npm.aegisgroup.ch pypi.aegisgroup.ch maven.aegisgroup.ch crates.aegisgroup.ch harbor.aegisgroup.ch proxy.aegisgroup.ch
```

## CA Trust

Clients must trust the private CA. Install `certs/ca-chain.pem`:

```bash
# Rocky/RHEL
sudo cp ca-chain.pem /etc/pki/ca-trust/source/anchors/airgap-proxy-ca.pem
sudo update-ca-trust

# Debian/Ubuntu
sudo cp ca-chain.pem /usr/local/share/ca-certificates/airgap-proxy-ca.crt
sudo update-ca-certificates

# Alpine
sudo cp ca-chain.pem /usr/local/share/ca-certificates/airgap-proxy-ca.crt
sudo update-ca-certificates
```
