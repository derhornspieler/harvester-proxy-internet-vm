# Design: proxy-internet-k8s-service

**Date:** 2026-03-11
**Status:** Approved
**Namespace:** `proxy-internet`

## Overview

Convert the VM-based airgap proxy (docker-compose on a dedicated VM) into a
Kubernetes-native service with horizontal pod autoscaling, shared cache via
Redis + MinIO, cert-manager with Vault PKI for automated TLS, Cilium egress
gateway replacing Squid, and full observability via Prometheus + Loki.

The new chart lives at `proxy-internet-k8s-service/` in the same repo.

## Architecture

```
                    ┌─────────────────────────────────┐
                    │   Traefik LB (192.168.48.4)     │
                    │   *.aegisgroup.ch proxy FQDNs   │
                    └──────────────┬──────────────────┘
                                   │
                    ┌──────────────▼──────────────────┐
                    │   IngressRoute (TLS via         │
                    │   cert-manager + Vault PKI)     │
                    └──────────────┬──────────────────┘
                                   │
          ┌────────────────────────┼────────────────────────┐
          │                        │                        │
   ┌──────▼──────┐   ┌────────────▼──────────┐   ┌────────▼────────┐
   │ nginx Pod 1 │   │    nginx Pod 2        │   │  nginx Pod N    │
   │ + exporter  │   │    + exporter         │   │  + exporter     │
   │ + minio-sync│   │    + minio-sync       │   │  + minio-sync   │
   └──────┬──────┘   └────────────┬──────────┘   └────────┬────────┘
          │                        │                        │
          └────────────┬───────────┴────────────┬───────────┘
                       │                        │
              ┌────────▼────────┐     ┌─────────▼─────────┐
              │  Redis HA (3)   │     │   MinIO (existing) │
              │  cache index    │     │   cached objects    │
              └─────────────────┘     └───────────────────┘
                       │
              ┌────────▼────────┐
              │  helm-sync (1)  │
              │  → Harbor push  │
              └─────────────────┘
```

## Components

### nginx Deployment (2-5 replicas, HPA)

Reverse proxy for all vhosts. Three containers per pod:

- **nginx** — serves all 12 vhosts on port 8080, health on 8081
- **nginx-exporter** sidecar — Prometheus metrics (request rate, bandwidth,
  cache hit/miss, connections)
- **minio-sync** sidecar — syncs cached objects to/from MinIO bucket

Local cache via `emptyDir` with `sizeLimit` (L1). MinIO is L2. Upstream is L3.

### helm-sync Deployment (1 replica)

Separate Deployment (not sidecar). Mirrors Helm chart tarballs to Harbor as OCI
artifacts. Exposed via Service `helm-sync-svc:8888`. nginx `mirror` directive
calls this service on chart downloads.

### Redis HA (3 replicas)

Managed by redis-operator. Shared cache index mapping upstream URLs to MinIO
object keys. Ephemeral — no persistence. Index rebuilds from MinIO listing on
startup.

### Cilium Egress Gateway

Replaces Squid forward proxy. `CiliumEgressGatewayPolicy` routes outbound
traffic from designated namespaces through a specific egress node. Hubble flow
logs piped to Loki for visibility.

### cert-manager + Vault PKI

Vault PKI engine as CA. cert-manager `ClusterIssuer` requests certs with SAN
list covering all 12 proxy FQDNs. 30-day cert lifetime, auto-rotated.

## Networking & DNS

**LoadBalancer IP:** `192.168.48.4`

**Dedicated Traefik instance** with IngressRoutes for all proxy FQDNs.

| FQDN | Backend |
|------|---------|
| `yum.aegisgroup.ch` | nginx Service :80 |
| `apt.aegisgroup.ch` | nginx Service :80 |
| `apk.aegisgroup.ch` | nginx Service :80 |
| `dl.aegisgroup.ch` | nginx Service :80 |
| `charts.aegisgroup.ch` | nginx Service :80 |
| `bin.aegisgroup.ch` | nginx Service :80 |
| `go.aegisgroup.ch` | nginx Service :80 |
| `npm.aegisgroup.ch` | nginx Service :80 |
| `pypi.aegisgroup.ch` | nginx Service :80 |
| `maven.aegisgroup.ch` | nginx Service :80 |
| `crates.aegisgroup.ch` | nginx Service :80 |
| `proxy.aegisgroup.ch` | Cilium egress (policy-based, no Service) |

All FQDNs resolve to `192.168.48.4` via DNS A records.

## Proxy Vhosts

### Package repos

| Vhost | Locations | Upstream |
|-------|-----------|----------|
| `yum` | `/rocky/9/`, `/epel/9/`, `/epel/RPM-GPG-KEY-EPEL-9`, `/rke2/latest/common/`, `/rke2/latest/1.34/`, `/rke2/public.key` | rockylinux.org, fedoraproject.org, rpm.rancher.io |
| `apt` | `/debian/`, `/debian-security/`, `/ubuntu/`, `/ubuntu-security/` | deb.debian.org, security.debian.org, archive.ubuntu.com, security.ubuntu.com |
| `apk` | `/alpine/v3.21/`, `/alpine/v3.20/`, `/alpine/edge/`, `/alpine/keys/` | dl-cdn.alpinelinux.org |

### Cloud images & keys

| Vhost | Locations | Upstream |
|-------|-----------|----------|
| `dl` | `/rocky/9/` | dl.rockylinux.org |
| `dl` | `/rocky/keys/` | dl.rockylinux.org (RPM-GPG-KEY-Rocky-9) |
| `dl` | `/debian/` | cloud.debian.org/images/cloud/ (qcow2 + SHA512SUMS + .sign) |
| `dl` | `/debian-keys/` | ftp-master.debian.org/keys/ |
| `dl` | `/ubuntu/` | cloud-images.ubuntu.com/ (img + SHA256SUMS + .gpg) |
| `dl` | `/ubuntu-keys/` | keyserver.ubuntu.com/pks/ |

### Language proxies

| Vhost | Locations | Upstream |
|-------|-----------|----------|
| `go` | `/`, `/sumdb/` | proxy.golang.org, sum.golang.org |
| `npm` | `/` | registry.npmjs.org |
| `pypi` | `/simple/`, `/pypi/`, `/packages/` | pypi.org, files.pythonhosted.org |
| `maven` | `/maven2/`, `/google/`, `/gradle-plugins/`, `/keys/` | repo1.maven.org, maven.google.com, plugins.gradle.org, keys.openpgp.org |
| `crates` | `/api/v1/crates/`, `/api/v1/crates/download/` | index.crates.io, static.crates.io |

### Other

| Vhost | Locations | Upstream |
|-------|-----------|----------|
| `charts` | Per-chart locations (11 repos) + `/mirror-sync` → helm-sync-svc | Various Helm repo URLs |
| `bin` | `/` (static file server) | Local PVC |

## Data Layer

### Cache flow

```
Request → nginx
  ├─ L1 hit (local emptyDir) → serve immediately
  ├─ L1 miss → check Redis index
  │   ├─ Redis says "in MinIO" → fetch from MinIO → serve + populate L1
  │   └─ Redis miss → fetch upstream → serve + write L1 + async sync to MinIO + update Redis
  └─ All miss → fetch upstream → serve
```

### Redis HA

- 3 replicas via redis-operator
- No persistence (RDB/AOF disabled)
- Cache index: `{upstream_url}` → `{minio_object_key, size, etag, last_accessed}`
- Rebuilds from MinIO listing on startup

### MinIO (existing)

- Bucket: `proxy-cache`
- Object key pattern: `{vhost}/{url_path}`
- Lifecycle policy: 30-day expiry for unused objects

### Per-pod local cache

- `emptyDir` with `sizeLimit` per cache zone
- L1 cache for hot objects
- Evicted on pod reschedule (by design)

## Scaling & Resources

### Resource requests (no limits)

| Component | CPU request | Memory request |
|-----------|-------------|----------------|
| nginx | 200m | 512Mi |
| nginx-exporter (sidecar) | 50m | 64Mi |
| minio-sync (sidecar) | 100m | 128Mi |
| helm-sync | 100m | 256Mi |
| Redis (per replica) | 100m | 256Mi |

### HPA

| Metric | Source | Target |
|--------|--------|--------|
| CPU utilization | metrics-server | 70% of request |
| Memory utilization | metrics-server | 80% of request |
| Network rx bytes/sec | cAdvisor → prometheus-adapter | 100MB/s per pod |
| nginx requests/sec | nginx-exporter → prometheus-adapter | 1000 rps per pod |
| nginx cache miss rate | nginx-exporter → prometheus-adapter | 60% miss ratio |

- Min replicas: 2
- Max replicas: 5
- Scale-up stabilization: 60s
- Scale-down stabilization: 300s

### PodDisruptionBudget

- nginx: `minAvailable: 1`
- Redis: `minAvailable: 2` (quorum)
- helm-sync: none

## Observability

### Prometheus

- nginx-exporter scrape target (per pod)
- prometheus-adapter exposes custom metrics to HPA
- ServiceMonitor CRs for nginx + Redis

### Loki

- nginx access logs in structured JSON format
- Hubble flow logs for egress visibility
- Retention: 30 days

### Grafana dashboards

- Cache hit/miss rates per vhost
- Bandwidth per vhost
- HPA scaling events
- Redis index size and latency
- MinIO bucket usage

## TLS

- cert-manager `ClusterIssuer` backed by Vault PKI engine
- Vault PKI root: existing Aegis Group Root CA
- Cert lifetime: 30 days, auto-renewed at 2/3 lifetime
- SAN list: all 12 proxy FQDNs (11 vhosts + proxy.aegisgroup.ch)
- Certificate Secret mounted into Traefik IngressRoute

## Security

- Cilium `CiliumNetworkPolicy`: nginx pods can only reach Redis, MinIO, and
  upstream internet (via egress gateway)
- `CiliumEgressGatewayPolicy`: replaces Squid ACLs
- No privileged containers
- `readOnlyRootFilesystem: true` (except emptyDir mounts)
- `runAsNonRoot: true`
- Resource requests only (no limits) — HPA scales instead of throttling

## Directory Structure

```
proxy-internet-k8s-service/
  Chart.yaml
  values.yaml
  templates/
    _helpers.tpl
    deployment-nginx.yaml
    deployment-helm-sync.yaml
    service-nginx.yaml
    service-helm-sync.yaml
    hpa-nginx.yaml
    pdb-nginx.yaml
    pdb-redis.yaml
    configmap-nginx-main.yaml
    configmap-nginx-confd.yaml
    configmap-nginx-includes.yaml
    configmap-charts-manifest.yaml
    configmap-minio-sync.yaml
    ingressroute.yaml
    certificate.yaml
    cilium-egress-policy.yaml
    cilium-network-policy.yaml
    redis-cluster.yaml
    servicemonitor-nginx.yaml
    servicemonitor-redis.yaml
    prometheusrule-alerts.yaml
    secret-harbor.yaml
    secret-minio.yaml
  dashboards/
    proxy-overview.json
```
