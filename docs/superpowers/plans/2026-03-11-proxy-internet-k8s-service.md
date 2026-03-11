# proxy-internet-k8s-service Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Kubernetes-native Helm chart for the internet proxy service with HPA, Redis HA shared cache, MinIO durable cache, cert-manager + Vault PKI TLS, Cilium egress gateway, and Prometheus + Loki observability.

**Architecture:** Nginx reverse proxy (2-5 replicas via HPA) with nginx-exporter and minio-sync sidecars, backed by Redis HA (3 replicas via redis-operator) for shared cache index and MinIO for durable object storage. helm-sync runs as a separate single-replica Deployment. TLS via cert-manager with Vault PKI issuer. Dedicated Traefik IngressRoute on LoadBalancer IP 192.168.48.4. Cilium replaces Squid for egress control.

**Tech Stack:** Helm 3, nginx 1.27-alpine, nginx-prometheus-exporter, redis-operator (OT Container Kit), cert-manager, Vault PKI, Traefik IngressRoute CRD, Cilium CiliumNetworkPolicy/CiliumEgressGatewayPolicy, prometheus-adapter, MinIO S3 SDK

**Design Spec:** `docs/superpowers/specs/2026-03-11-proxy-internet-k8s-service-design.md`

**IMPORTANT:** All git commits in this plan MUST append the following trailer:
`Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`
Use HEREDOC format for commit messages (see global git standards).

**Note:** The spec directory tree lists `redis-cluster.yaml` and `secret-minio.yaml`.
This plan supersedes those with `redis-replication.yaml` + `redis-sentinel.yaml`
(proper redis-operator CRDs) and `externalsecret-minio.yaml` (Vault-backed via ESO
instead of raw K8s Secret — see ADR-1 below).

### ADR-1: Vault-backed ExternalSecret for MinIO credentials

- **Status**: Accepted
- **Decision**: Use ExternalSecret (ESO) pulling from Vault instead of a plain K8s Secret
- **Context**: MinIO credentials are sensitive; the cluster already has ESO + Vault SecretStore configured
- **Consequences**: Requires Vault path `kv/services/minio` with `access-key` and `secret-key` fields
- **Alternatives Considered**: Raw K8s Secret (rejected — violates supply chain security standards)

---

## File Structure

```
proxy-internet-k8s-service/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── _helpers.tpl
│   ├── configmap-nginx-main.yaml
│   ├── configmap-nginx-confd.yaml        # 11 vhost configs (proxy.aegisgroup.ch has no nginx vhost — Cilium egress only)
│   ├── configmap-nginx-includes.yaml
│   ├── configmap-charts-manifest.yaml
│   ├── configmap-minio-sync.yaml
│   ├── deployment-nginx.yaml
│   ├── deployment-helm-sync.yaml
│   ├── service-nginx.yaml
│   ├── service-helm-sync.yaml
│   ├── hpa-nginx.yaml
│   ├── pdb-nginx.yaml
│   ├── pdb-redis.yaml
│   ├── redis-replication.yaml
│   ├── redis-sentinel.yaml
│   ├── ingressroute.yaml                 # 11 IngressRoutes (no proxy.aegisgroup.ch — Cilium handles that)
│   ├── traefik-service.yaml
│   ├── certificate.yaml                  # 12 SANs (includes proxy.aegisgroup.ch for future use)
│   ├── cluster-issuer.yaml
│   ├── cilium-egress-policy.yaml
│   ├── cilium-network-policy.yaml
│   ├── servicemonitor-nginx.yaml
│   ├── servicemonitor-redis.yaml
│   ├── prometheusrule-alerts.yaml
│   ├── secret-harbor.yaml
│   └── externalsecret-minio.yaml
```

---

## Chunk 1: Chart Scaffolding, Helpers, and Values

### Task 1: Create Chart.yaml

**Files:**
- Create: `proxy-internet-k8s-service/Chart.yaml`

- [ ] **Step 1: Create chart directory and Chart.yaml**

```yaml
apiVersion: v2
name: proxy-internet-k8s-service
description: >-
  Kubernetes-native internet proxy with nginx caching reverse proxy,
  Redis HA shared cache index, MinIO durable cache, and HPA scaling
version: 0.1.0
appVersion: "1.0.0"
type: application
keywords:
  - proxy
  - cache
  - airgap
  - nginx
  - helm
  - harbor
maintainers:
  - name: derhornspieler
```

- [ ] **Step 2: Validate chart structure**

Run: `helm lint proxy-internet-k8s-service/`
Expected: basic lint pass (warnings about missing templates OK at this stage)

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/Chart.yaml
git commit -m "feat(k8s-service): scaffold Chart.yaml for proxy-internet-k8s-service

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Create _helpers.tpl

**Files:**
- Create: `proxy-internet-k8s-service/templates/_helpers.tpl`

- [ ] **Step 1: Write helpers template**

Follow existing chart convention but with new chart name `proxy-internet`.

```gotemplate
{{/*
Expand the name of the chart.
*/}}
{{- define "proxy-internet.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "proxy-internet.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "proxy-internet.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "proxy-internet.labels" -}}
helm.sh/chart: {{ include "proxy-internet.chart" . }}
{{ include "proxy-internet.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "proxy-internet.selectorLabels" -}}
app.kubernetes.io/name: {{ include "proxy-internet.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Harbor secret name — use existing or auto-generated.
*/}}
{{- define "proxy-internet.harborSecretName" -}}
{{- if .Values.harbor.existingSecret }}
{{- .Values.harbor.existingSecret }}
{{- else }}
{{- include "proxy-internet.fullname" . }}-harbor
{{- end }}
{{- end }}

{{/*
Charts manifest — generates pipe-delimited manifest for helm-sync.
*/}}
{{- define "proxy-internet.chartsManifest" -}}
{{- range .Values.charts }}
http|{{ .source }}|{{ .version }}|{{ .harborProject }}|{{ .name }}|{{ .envVar }}
{{- end }}
{{- end }}

{{/*
MinIO secret name.
*/}}
{{- define "proxy-internet.minioSecretName" -}}
{{- if .Values.minio.existingSecret }}
{{- .Values.minio.existingSecret }}
{{- else }}
{{- include "proxy-internet.fullname" . }}-minio
{{- end }}
{{- end }}

{{/*
Full list of proxy FQDNs for TLS SAN and IngressRoute.
*/}}
{{- define "proxy-internet.proxyHosts" -}}
{{- $domain := .Values.domain }}
{{- range list "yum" "apt" "apk" "dl" "charts" "bin" "go" "npm" "pypi" "maven" "crates" }}
- {{ . }}.{{ $domain }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Verify template renders**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/_helpers.tpl 2>&1 || echo "OK - helpers don't render standalone"`
Expected: no syntax errors

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/templates/_helpers.tpl
git commit -m "feat(k8s-service): add _helpers.tpl with naming, labels, and utility templates"
```

---

### Task 3: Create values.yaml

**Files:**
- Create: `proxy-internet-k8s-service/values.yaml`

- [ ] **Step 1: Write values.yaml**

```yaml
# Base domain for all proxy hostnames
domain: aegisgroup.ch

# --- Harbor ---
harbor:
  host: harbor.aegisgroup.ch
  existingSecret: ""
  user: "robot$helm-sync"
  pass: "changeme"

# --- MinIO (existing) ---
minio:
  endpoint: "minio.minio.svc:9000"
  bucket: "proxy-cache"
  region: ""
  existingSecret: ""
  accessKey: ""
  secretKey: ""
  useSSL: false
  lifecycleDays: 30

# --- Redis HA ---
redis:
  replicas: 3
  sentinel:
    replicas: 3
  image: redis:7-alpine
  resources:
    requests:
      cpu: 100m
      memory: 256Mi

# --- Nginx Proxy ---
nginx:
  replicaCount: 2
  image: nginx:1.27-alpine
  exporterImage: nginx/nginx-prometheus-exporter:1.4
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
  exporter:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
  minioSync:
    image: alpine:3.21
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
  cache:
    # emptyDir sizeLimit per cache zone (L1 local cache)
    rpm: 5Gi
    charts: 1Gi
    downloads: 10Gi
    go: 2Gi
    npm: 3Gi
    pypi: 3Gi
    maven: 3Gi
    crates: 2Gi

# --- Static binaries ---
binaries:
  enabled: false
  existingClaim: ""

# --- HPA ---
hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  metrics:
    # Custom metrics require prometheus-adapter — set to false until configured
    customMetricsEnabled: false
    cpu:
      targetAverageUtilization: 70
    memory:
      targetAverageUtilization: 80
    networkRxBytesPerSec:
      targetValue: "100M"
    requestsPerSec:
      targetValue: "1000"
    cacheMissRate:
      targetValue: "60"
  scaleUp:
    stabilizationWindowSeconds: 60
    podCount: 1
    periodSeconds: 60
  scaleDown:
    stabilizationWindowSeconds: 300
    podCount: 1
    periodSeconds: 60

# --- PDB ---
pdb:
  nginx:
    minAvailable: 1
  redis:
    minAvailable: 2

# --- helm-sync ---
helmSync:
  replicaCount: 1
  image:
    repository: ""
    tag: latest
    pullPolicy: IfNotPresent
  resources:
    requests:
      cpu: 100m
      memory: 256Mi

# --- Traefik IngressRoute ---
ingress:
  enabled: true
  loadBalancerIP: "192.168.48.4"
  entryPoints:
    - websecure
  tls:
    secretName: proxy-internet-tls

# --- cert-manager + Vault PKI ---
certManager:
  enabled: true
  issuer:
    name: vault-pki-issuer
    kind: ClusterIssuer
  vaultPKI:
    server: "https://vault.vault.svc:8200"
    path: "pki/sign/proxy-internet"
    authPath: "kubernetes"
    role: "proxy-internet"
    serviceAccountRef: "cert-manager"
  duration: 720h        # 30 days
  renewBefore: 240h     # renew with 10 days remaining (at 2/3 of lifetime elapsed)

# --- Cilium ---
cilium:
  egressGateway:
    enabled: true
    egressIP: ""
    nodeSelector:
      kubernetes.io/os: linux
  networkPolicy:
    enabled: true

# --- Observability ---
monitoring:
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 10s
  prometheusRule:
    enabled: true
  loki:
    enabled: true

# --- Security context ---
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL

# --- Helm charts manifest (same as existing chart) ---
charts:
  - source: https://charts.jetstack.io
    version: v1.19.3
    harborProject: charts.jetstack.io
    name: cert-manager
    envVar: HELM_OCI_CERT_MANAGER
    locationPath: /jetstack/
  - source: https://cloudnative-pg.github.io/charts
    version: "0.27.1"
    harborProject: cloudnative-pg.github.io
    name: cloudnative-pg
    envVar: HELM_OCI_CNPG
    locationPath: /cnpg/
  - source: https://helm.releases.hashicorp.com
    version: "0.32.0"
    harborProject: helm.releases.hashicorp.com
    name: vault
    envVar: HELM_OCI_VAULT
    locationPath: /hashicorp/
  - source: https://helm.goharbor.io
    version: "1.18.2"
    harborProject: helm.goharbor.io
    name: harbor
    envVar: HELM_OCI_HARBOR
    locationPath: /goharbor/
  - source: https://prometheus-community.github.io/helm-charts
    version: "72.6.2"
    harborProject: prometheus-community.github.io
    name: kube-prometheus-stack
    envVar: HELM_OCI_KPS
    locationPath: /prometheus-community/
  - source: https://external-secrets.io
    version: latest
    harborProject: charts.external-secrets.io
    name: external-secrets
    envVar: HELM_OCI_EXTERNAL_SECRETS
    locationPath: /external-secrets/
  - source: https://kubernetes.github.io/autoscaler
    version: latest
    harborProject: kubernetes.github.io
    name: cluster-autoscaler
    envVar: HELM_OCI_CLUSTER_AUTOSCALER
    locationPath: /autoscaler/
  - source: https://ot-container-kit.github.io/helm-charts/
    version: latest
    harborProject: ot-container-kit.github.io
    name: redis-operator
    envVar: HELM_OCI_REDIS_OPERATOR
    locationPath: /ot-helm/
  - source: https://helm.kasmweb.com/
    version: "1.1181.0"
    harborProject: helm.kasmweb.com
    name: kasm
    envVar: HELM_OCI_KASM
    locationPath: /kasmtech/
  - source: https://charts.gitlab.io
    version: latest
    harborProject: charts.gitlab.io
    name: gitlab-runner
    envVar: HELM_OCI_GITLAB_RUNNER
    locationPath: /gitlab/
  - source: https://mariadb-operator.github.io/mariadb-operator
    version: latest
    harborProject: mariadb-operator.github.io
    name: mariadb-operator
    envVar: HELM_OCI_MARIADB_OPERATOR
    locationPath: /mariadb-operator/
```

- [ ] **Step 2: Validate chart with values**

Run: `helm lint proxy-internet-k8s-service/`
Expected: lint passes (warnings about missing templates OK)

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/values.yaml
git commit -m "feat(k8s-service): add values.yaml with full configuration"
```

---

## Chunk 2: Nginx ConfigMaps

### Task 4: Create configmap-nginx-main.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/configmap-nginx-main.yaml`

- [ ] **Step 1: Write nginx main config ConfigMap**

Same pattern as existing chart but with health on port 8081, resolver, and includes for all cache zones.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx-main
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
data:
  nginx.conf: |
    worker_processes auto;
    error_log /var/log/nginx/error.log warn;
    pid /tmp/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        resolver 8.8.8.8 1.1.1.1 valid=300s;
        resolver_timeout 5s;

        include /etc/nginx/includes/cache.conf;

        # Health check endpoint on separate port
        server {
            listen 8081;
            server_name _;
            location /healthz {
                access_log off;
                return 200 "ok\n";
            }
            location /stub_status {
                stub_status;
                access_log off;
            }
        }

        # Structured JSON access log for Loki
        log_format json_combined escape=json
          '{'
            '"time":"$time_iso8601",'
            '"remote_addr":"$remote_addr",'
            '"request":"$request",'
            '"status":$status,'
            '"body_bytes_sent":$body_bytes_sent,'
            '"request_time":$request_time,'
            '"upstream_response_time":"$upstream_response_time",'
            '"upstream_cache_status":"$upstream_cache_status",'
            '"server_name":"$server_name",'
            '"http_user_agent":"$http_user_agent"'
          '}';

        access_log /var/log/nginx/access.log json_combined;

        include /etc/nginx/conf.d/*.conf;
    }
```

- [ ] **Step 2: Verify template renders**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/configmap-nginx-main.yaml`
Expected: valid ConfigMap with nginx.conf key

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/templates/configmap-nginx-main.yaml
git commit -m "feat(k8s-service): add nginx main config with JSON logging and stub_status"
```

---

### Task 5: Create configmap-nginx-includes.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/configmap-nginx-includes.yaml`

- [ ] **Step 1: Write includes ConfigMap with all 8 cache zones**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx-includes
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
data:
  proxy-defaults.conf: |
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_ssl_server_name on;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;
    proxy_connect_timeout 30s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    proxy_buffering on;
    proxy_buffer_size 16k;
    proxy_buffers 8 32k;
    proxy_busy_buffers_size 64k;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

  cache.conf: |
    proxy_cache_path /var/cache/nginx/rpm levels=1:2 keys_zone=rpm_cache:50m max_size=20g inactive=30d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/charts levels=1:2 keys_zone=charts_cache:10m max_size=2g inactive=1d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/downloads levels=1:2 keys_zone=downloads_cache:20m max_size=30g inactive=30d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/go levels=1:2 keys_zone=go_cache:20m max_size=5g inactive=30d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/npm levels=1:2 keys_zone=npm_cache:20m max_size=10g inactive=30d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/pypi levels=1:2 keys_zone=pypi_cache:20m max_size=10g inactive=30d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/maven levels=1:2 keys_zone=maven_cache:20m max_size=10g inactive=30d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/crates levels=1:2 keys_zone=crates_cache:10m max_size=5g inactive=30d use_temp_path=off;
```

- [ ] **Step 2: Verify template renders**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/configmap-nginx-includes.yaml`
Expected: ConfigMap with both proxy-defaults.conf and cache.conf keys, 8 cache zones

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/templates/configmap-nginx-includes.yaml
git commit -m "feat(k8s-service): add nginx includes with proxy defaults and 8 cache zones"
```

---

### Task 6: Create configmap-nginx-confd.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/configmap-nginx-confd.yaml`

This is the largest ConfigMap — contains all 12 vhost configs. All listen on port 8080 (TLS at Ingress). Uses `{{ .Values.domain }}` for server_name.

- [ ] **Step 1: Write conf.d ConfigMap with all vhosts**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx-confd
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
data:
  yum.conf: |
    server {
        listen 8080;
        server_name yum.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location /rocky/9/ {
            proxy_pass https://dl.rockylinux.org/pub/rocky/9/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /epel/9/ {
            proxy_pass https://dl.fedoraproject.org/pub/epel/9/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location = /epel/RPM-GPG-KEY-EPEL-9 {
            proxy_pass https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /rke2/latest/common/ {
            proxy_pass https://rpm.rancher.io/rke2/latest/common/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /rke2/latest/1.34/ {
            proxy_pass https://rpm.rancher.io/rke2/latest/1.34/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location = /rke2/public.key {
            proxy_pass https://rpm.rancher.io/public.key;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  apt.conf: |
    server {
        listen 8080;
        server_name apt.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location /debian/ {
            proxy_pass https://deb.debian.org/debian/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /debian-security/ {
            proxy_pass https://security.debian.org/debian-security/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /ubuntu/ {
            proxy_pass https://archive.ubuntu.com/ubuntu/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /ubuntu-security/ {
            proxy_pass https://security.ubuntu.com/ubuntu/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  apk.conf: |
    server {
        listen 8080;
        server_name apk.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location /alpine/v3.21/ {
            proxy_pass https://dl-cdn.alpinelinux.org/alpine/v3.21/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /alpine/v3.20/ {
            proxy_pass https://dl-cdn.alpinelinux.org/alpine/v3.20/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /alpine/edge/ {
            proxy_pass https://dl-cdn.alpinelinux.org/alpine/edge/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /alpine/keys/ {
            proxy_pass https://dl-cdn.alpinelinux.org/alpine/keys/;
            proxy_cache rpm_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  dl.conf: |
    server {
        listen 8080;
        server_name dl.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        # Rocky Linux cloud images
        location /rocky/9/ {
            proxy_pass https://dl.rockylinux.org/pub/rocky/9/;
            proxy_cache downloads_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 4096m;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location = /rocky/keys/RPM-GPG-KEY-Rocky-9 {
            proxy_pass https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9;
            proxy_cache downloads_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }

        # Debian cloud images + SHA512SUMS + .sign
        location /debian/ {
            proxy_pass https://cloud.debian.org/images/cloud/;
            proxy_cache downloads_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 4096m;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /debian-keys/ {
            proxy_pass https://ftp-master.debian.org/keys/;
            proxy_cache downloads_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }

        # Ubuntu cloud images + SHA256SUMS + .gpg
        location /ubuntu/ {
            proxy_pass https://cloud-images.ubuntu.com/;
            proxy_cache downloads_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 4096m;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /ubuntu-keys/ {
            proxy_pass https://keyserver.ubuntu.com/pks/;
            proxy_cache downloads_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  charts.conf: |
    server {
        listen 8080;
        server_name charts.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        set $helm_sync_upstream http://{{ include "proxy-internet.fullname" . }}-helm-sync:8888;

        location = /mirror-sync {
            internal;
            proxy_pass $helm_sync_upstream/sync$request_uri;
            proxy_set_header Host $host;
        }

        {{- range .Values.charts }}
        location {{ .locationPath }} {
            proxy_pass {{ .source | trimSuffix "/" }}/;
            mirror /mirror-sync;
            mirror_request_body off;
            proxy_cache charts_cache;
            proxy_cache_valid 200 1d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        {{- end }}
    }

  bin.conf: |
    server {
        listen 8080;
        server_name bin.{{ .Values.domain }};

        root /srv/bin;
        autoindex on;

        location / {
            try_files $uri =404;
            add_header Cache-Control "public, max-age=86400, immutable";
        }
    }

  go.conf: |
    server {
        listen 8080;
        server_name go.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location / {
            proxy_pass https://proxy.golang.org;
            proxy_cache go_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 512m;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /sumdb/ {
            proxy_pass https://sum.golang.org/;
            proxy_cache go_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  npm.conf: |
    server {
        listen 8080;
        server_name npm.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location / {
            proxy_pass https://registry.npmjs.org;
            proxy_cache npm_cache;
            proxy_cache_valid 200 7d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 512m;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  pypi.conf: |
    server {
        listen 8080;
        server_name pypi.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location /simple/ {
            proxy_pass https://pypi.org/simple/;
            proxy_cache pypi_cache;
            proxy_cache_valid 200 1d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /pypi/ {
            proxy_pass https://pypi.org/pypi/;
            proxy_cache pypi_cache;
            proxy_cache_valid 200 1d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /packages/ {
            proxy_pass https://files.pythonhosted.org/packages/;
            proxy_cache pypi_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 512m;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  maven.conf: |
    server {
        listen 8080;
        server_name maven.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location /maven2/ {
            proxy_pass https://repo1.maven.org/maven2/;
            proxy_cache maven_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 512m;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /google/ {
            proxy_pass https://maven.google.com/;
            proxy_cache maven_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /gradle-plugins/ {
            proxy_pass https://plugins.gradle.org/m2/;
            proxy_cache maven_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /keys/ {
            proxy_pass https://keys.openpgp.org/;
            proxy_cache maven_cache;
            proxy_cache_valid 200 30d;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }

  crates.conf: |
    server {
        listen 8080;
        server_name crates.{{ .Values.domain }};

        include /etc/nginx/includes/proxy-defaults.conf;

        location /api/v1/crates/ {
            proxy_pass https://index.crates.io/;
            proxy_cache crates_cache;
            proxy_cache_valid 200 1d;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating;
            add_header X-Cache-Status $upstream_cache_status;
        }
        location /api/v1/crates/download/ {
            proxy_pass https://static.crates.io/crates/;
            proxy_cache crates_cache;
            proxy_cache_valid 200 30d;
            proxy_cache_use_stale error timeout updating;
            proxy_max_temp_file_size 256m;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }
```

- [ ] **Step 2: Verify template renders with all vhosts**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/configmap-nginx-confd.yaml`
Expected: ConfigMap with 11 keys (yum, apt, apk, dl, charts, bin, go, npm, pypi, maven, crates — no `proxy.conf` since `proxy.aegisgroup.ch` is Cilium egress only). Note: apt and apk intentionally share `rpm_cache` zone — this matches the existing docker-compose setup where all OS package repos share one cache zone for simplicity

- [ ] **Step 3: Verify charts.conf has dynamic locations**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/configmap-nginx-confd.yaml | grep "location /jetstack/"`
Expected: location block for jetstack appears

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/configmap-nginx-confd.yaml
git commit -m "feat(k8s-service): add all 12 nginx vhost configs (package, cloud image, language proxies)"
```

---

### Task 7: Create configmap-charts-manifest.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/configmap-charts-manifest.yaml`

- [ ] **Step 1: Write charts manifest ConfigMap**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "proxy-internet.fullname" . }}-charts-manifest
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: helm-sync
data:
  charts.manifest: |
    {{- include "proxy-internet.chartsManifest" . | nindent 4 }}
```

- [ ] **Step 2: Verify**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/configmap-charts-manifest.yaml`
Expected: pipe-delimited manifest lines for all 11 charts

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/templates/configmap-charts-manifest.yaml
git commit -m "feat(k8s-service): add charts manifest ConfigMap for helm-sync"
```

---

### Task 8: Create configmap-minio-sync.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/configmap-minio-sync.yaml`

This ConfigMap holds the minio-sync sidecar script that manages L1↔L2 cache synchronization.

- [ ] **Step 1: Write minio-sync ConfigMap**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "proxy-internet.fullname" . }}-minio-sync
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
data:
  minio-sync.sh: |
    #!/bin/sh
    set -eu

    # minio-sync — L1 (local emptyDir) ↔ L2 (MinIO) cache synchronization
    # Watches nginx cache dirs via inotifywait, uploads new objects to MinIO,
    # and pre-populates L1 from MinIO on startup.

    MINIO_ENDPOINT="${MINIO_ENDPOINT}"
    MINIO_BUCKET="${MINIO_BUCKET}"
    MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY}"
    MINIO_SECRET_KEY="${MINIO_SECRET_KEY}"
    MINIO_USE_SSL="${MINIO_USE_SSL:-false}"
    CACHE_DIRS="/var/cache/nginx"
    SYNC_INTERVAL="${SYNC_INTERVAL:-60}"

    mc_scheme="http"
    if [ "$MINIO_USE_SSL" = "true" ]; then
      mc_scheme="https"
    fi

    # Configure mc alias
    mc alias set cache "${mc_scheme}://${MINIO_ENDPOINT}" \
      "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" --api S3v4

    # Ensure bucket exists
    mc mb --ignore-existing "cache/${MINIO_BUCKET}"

    echo "[minio-sync] Starting cache sync loop (interval: ${SYNC_INTERVAL}s)"

    while true; do
      # Upload new/changed files from L1 to MinIO
      for zone_dir in "${CACHE_DIRS}"/*/; do
        zone=$(basename "$zone_dir")
        mc mirror --overwrite --remove --quiet \
          "${zone_dir}" "cache/${MINIO_BUCKET}/${zone}/" 2>/dev/null || true
      done

      # Download from MinIO to L1 (pre-populate)
      for zone_dir in "${CACHE_DIRS}"/*/; do
        zone=$(basename "$zone_dir")
        mc mirror --overwrite --quiet \
          "cache/${MINIO_BUCKET}/${zone}/" "${zone_dir}" 2>/dev/null || true
      done

      sleep "${SYNC_INTERVAL}"
    done
```

- [ ] **Step 2: Verify**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/configmap-minio-sync.yaml`
Expected: ConfigMap with minio-sync.sh script

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/templates/configmap-minio-sync.yaml
git commit -m "feat(k8s-service): add minio-sync sidecar script for L1↔L2 cache sync"
```

---

## Chunk 3: Deployments and Services

### Task 9: Create deployment-nginx.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/deployment-nginx.yaml`

Three containers: nginx, nginx-exporter, minio-sync. Uses emptyDir for L1 cache.

- [ ] **Step 1: Write nginx Deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
spec:
  replicas: {{ .Values.nginx.replicaCount }}
  selector:
    matchLabels:
      {{- include "proxy-internet.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: nginx
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        {{- include "proxy-internet.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: nginx
      annotations:
        checksum/nginx-main: {{ include (print $.Template.BasePath "/configmap-nginx-main.yaml") . | sha256sum }}
        checksum/nginx-confd: {{ include (print $.Template.BasePath "/configmap-nginx-confd.yaml") . | sha256sum }}
        checksum/nginx-includes: {{ include (print $.Template.BasePath "/configmap-nginx-includes.yaml") . | sha256sum }}
    spec:
      containers:
        # --- nginx ---
        - name: nginx
          image: {{ .Values.nginx.image }}
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: health
              containerPort: 8081
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: health
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: health
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              {{- toYaml .Values.nginx.resources.requests | nindent 14 }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          volumeMounts:
            - name: nginx-main
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: nginx-confd
              mountPath: /etc/nginx/conf.d
              readOnly: true
            - name: nginx-includes
              mountPath: /etc/nginx/includes
              readOnly: true
            - name: cache-rpm
              mountPath: /var/cache/nginx/rpm
            - name: cache-charts
              mountPath: /var/cache/nginx/charts
            - name: cache-downloads
              mountPath: /var/cache/nginx/downloads
            - name: cache-go
              mountPath: /var/cache/nginx/go
            - name: cache-npm
              mountPath: /var/cache/nginx/npm
            - name: cache-pypi
              mountPath: /var/cache/nginx/pypi
            - name: cache-maven
              mountPath: /var/cache/nginx/maven
            - name: cache-crates
              mountPath: /var/cache/nginx/crates
            - name: nginx-tmp
              mountPath: /tmp
            - name: nginx-log
              mountPath: /var/log/nginx
            {{- if .Values.binaries.enabled }}
            - name: binaries
              mountPath: /srv/bin
              readOnly: true
            {{- end }}

        # --- nginx-exporter ---
        - name: nginx-exporter
          image: {{ .Values.nginx.exporterImage }}
          args:
            - --nginx.scrape-uri=http://127.0.0.1:8081/stub_status
          ports:
            - name: metrics
              containerPort: 9113
              protocol: TCP
          resources:
            requests:
              {{- toYaml .Values.nginx.exporter.resources.requests | nindent 14 }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}

        # --- minio-sync ---
        - name: minio-sync
          image: {{ .Values.nginx.minioSync.image }}
          command: ["/bin/sh", "/opt/minio-sync/minio-sync.sh"]
          env:
            - name: MINIO_ENDPOINT
              value: {{ .Values.minio.endpoint | quote }}
            - name: MINIO_BUCKET
              value: {{ .Values.minio.bucket | quote }}
            - name: MINIO_USE_SSL
              value: {{ .Values.minio.useSSL | quote }}
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ include "proxy-internet.minioSecretName" . }}
                  key: access-key
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ include "proxy-internet.minioSecretName" . }}
                  key: secret-key
          resources:
            requests:
              {{- toYaml .Values.nginx.minioSync.resources.requests | nindent 14 }}
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: minio-sync-script
              mountPath: /opt/minio-sync
              readOnly: true
            - name: cache-rpm
              mountPath: /var/cache/nginx/rpm
            - name: cache-charts
              mountPath: /var/cache/nginx/charts
            - name: cache-downloads
              mountPath: /var/cache/nginx/downloads
            - name: cache-go
              mountPath: /var/cache/nginx/go
            - name: cache-npm
              mountPath: /var/cache/nginx/npm
            - name: cache-pypi
              mountPath: /var/cache/nginx/pypi
            - name: cache-maven
              mountPath: /var/cache/nginx/maven
            - name: cache-crates
              mountPath: /var/cache/nginx/crates
            - name: mc-config
              mountPath: /.mc

      volumes:
        - name: nginx-main
          configMap:
            name: {{ include "proxy-internet.fullname" . }}-nginx-main
        - name: nginx-confd
          configMap:
            name: {{ include "proxy-internet.fullname" . }}-nginx-confd
        - name: nginx-includes
          configMap:
            name: {{ include "proxy-internet.fullname" . }}-nginx-includes
        - name: minio-sync-script
          configMap:
            name: {{ include "proxy-internet.fullname" . }}-minio-sync
            defaultMode: 0755
        - name: nginx-tmp
          emptyDir: {}
        - name: nginx-log
          emptyDir: {}
        - name: mc-config
          emptyDir: {}
        # L1 cache — emptyDir with sizeLimit
        - name: cache-rpm
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.rpm }}
        - name: cache-charts
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.charts }}
        - name: cache-downloads
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.downloads }}
        - name: cache-go
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.go }}
        - name: cache-npm
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.npm }}
        - name: cache-pypi
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.pypi }}
        - name: cache-maven
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.maven }}
        - name: cache-crates
          emptyDir:
            sizeLimit: {{ .Values.nginx.cache.crates }}
        {{- if .Values.binaries.enabled }}
        - name: binaries
          persistentVolumeClaim:
            claimName: {{ .Values.binaries.existingClaim | default (printf "%s-binaries" (include "proxy-internet.fullname" .)) }}
        {{- end }}
```

- [ ] **Step 2: Verify template renders**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/deployment-nginx.yaml`
Expected: Deployment with 3 containers, 8 emptyDir cache volumes, correct configmap refs

- [ ] **Step 3: Verify security context applied**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/deployment-nginx.yaml | grep -A3 "runAsNonRoot"`
Expected: `runAsNonRoot: true` appears for containers

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/deployment-nginx.yaml
git commit -m "feat(k8s-service): add nginx Deployment with exporter and minio-sync sidecars"
```

---

### Task 10: Create service-nginx.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/service-nginx.yaml`

- [ ] **Step 1: Write nginx Service**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
spec:
  selector:
    {{- include "proxy-internet.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
    - name: metrics
      port: 9113
      targetPort: 9113
      protocol: TCP
```

- [ ] **Step 2: Verify**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/service-nginx.yaml`
Expected: Service with http (80→8080) and metrics (9113) ports

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/templates/service-nginx.yaml
git commit -m "feat(k8s-service): add nginx Service with http and metrics ports"
```

---

### Task 11: Create deployment-helm-sync.yaml and service-helm-sync.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/deployment-helm-sync.yaml`
- Create: `proxy-internet-k8s-service/templates/service-helm-sync.yaml`

- [ ] **Step 1: Write helm-sync Deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "proxy-internet.fullname" . }}-helm-sync
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: helm-sync
spec:
  replicas: {{ .Values.helmSync.replicaCount }}
  selector:
    matchLabels:
      {{- include "proxy-internet.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: helm-sync
  template:
    metadata:
      labels:
        {{- include "proxy-internet.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: helm-sync
      annotations:
        checksum/charts-manifest: {{ include (print $.Template.BasePath "/configmap-charts-manifest.yaml") . | sha256sum }}
    spec:
      containers:
        - name: helm-sync
          image: "{{ .Values.helmSync.image.repository }}:{{ .Values.helmSync.image.tag }}"
          imagePullPolicy: {{ .Values.helmSync.image.pullPolicy }}
          ports:
            - name: sync
              containerPort: 8888
              protocol: TCP
          env:
            - name: HARBOR_HOST
              value: {{ .Values.harbor.host | quote }}
            - name: HARBOR_USER
              valueFrom:
                secretKeyRef:
                  name: {{ include "proxy-internet.harborSecretName" . }}
                  key: HARBOR_USER
            - name: HARBOR_PASS
              valueFrom:
                secretKeyRef:
                  name: {{ include "proxy-internet.harborSecretName" . }}
                  key: HARBOR_PASS
            - name: HELM_SYNC_PORT
              value: "8888"
          readinessProbe:
            httpGet:
              path: /healthz
              port: sync
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: sync
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              {{- toYaml .Values.helmSync.resources.requests | nindent 14 }}
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: charts-manifest
              mountPath: /opt/helm-sync/charts.manifest
              subPath: charts.manifest
              readOnly: true
            - name: helm-sync-tmp
              mountPath: /tmp
            - name: helm-sync-log
              mountPath: /var/log/helm-sync
            - name: helm-sync-locks
              mountPath: /tmp/helm-sync-locks
            - name: helm-cache
              mountPath: /.cache/helm
            - name: helm-config
              mountPath: /.config/helm
      volumes:
        - name: charts-manifest
          configMap:
            name: {{ include "proxy-internet.fullname" . }}-charts-manifest
        - name: helm-sync-tmp
          emptyDir: {}
        - name: helm-sync-log
          emptyDir: {}
        - name: helm-sync-locks
          emptyDir: {}
        - name: helm-cache
          emptyDir: {}
        - name: helm-config
          emptyDir: {}
```

- [ ] **Step 2: Write helm-sync Service**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "proxy-internet.fullname" . }}-helm-sync
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: helm-sync
spec:
  selector:
    {{- include "proxy-internet.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: helm-sync
  ports:
    - name: sync
      port: 8888
      targetPort: 8888
      protocol: TCP
```

- [ ] **Step 3: Verify charts.conf references helm-sync service**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/configmap-nginx-confd.yaml | grep helm_sync_upstream`
Expected: `set $helm_sync_upstream http://<fullname>-helm-sync:8888`

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/deployment-helm-sync.yaml \
        proxy-internet-k8s-service/templates/service-helm-sync.yaml
git commit -m "feat(k8s-service): add helm-sync Deployment and Service (separate from nginx)"
```

---

## Chunk 4: Redis HA, Secrets, and HPA/PDB

### Task 12: Create Redis HA resources

**Files:**
- Create: `proxy-internet-k8s-service/templates/redis-replication.yaml`
- Create: `proxy-internet-k8s-service/templates/redis-sentinel.yaml`

Uses OT Container Kit redis-operator CRDs: `redisreplications.redis.redis.opstreelabs.in` and `redissentinels.redis.redis.opstreelabs.in`.

- [ ] **Step 1: Write Redis Replication CR**

```yaml
{{- if .Values.redis.replicas }}
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisReplication
metadata:
  name: {{ include "proxy-internet.fullname" . }}-redis
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  clusterSize: {{ .Values.redis.replicas }}
  kubernetesConfig:
    image: {{ .Values.redis.image }}
    resources:
      requests:
        {{- toYaml .Values.redis.resources.requests | nindent 8 }}
  redisConfig:
    additionalRedisConfig: |
      maxmemory-policy allkeys-lru
      save ""
      appendonly no
  storage: {}
{{- end }}
```

- [ ] **Step 2: Write Redis Sentinel CR**

```yaml
{{- if .Values.redis.sentinel.replicas }}
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisSentinel
metadata:
  name: {{ include "proxy-internet.fullname" . }}-redis-sentinel
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  clusterSize: {{ .Values.redis.sentinel.replicas }}
  kubernetesConfig:
    image: {{ .Values.redis.image }}
    resources:
      requests:
        {{- toYaml .Values.redis.resources.requests | nindent 8 }}
  redisSentinelConfig:
    redisReplicationName: {{ include "proxy-internet.fullname" . }}-redis
    masterGroupName: "mymaster"
    redisPort: "6379"
    quorum: "{{ div (add .Values.redis.sentinel.replicas 1) 2 }}"
{{- end }}
```

- [ ] **Step 3: Verify CRDs render**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/redis-replication.yaml`
Expected: RedisReplication with 3 replicas, no persistence, LRU eviction

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/redis-replication.yaml \
        proxy-internet-k8s-service/templates/redis-sentinel.yaml
git commit -m "feat(k8s-service): add Redis HA via redis-operator (replication + sentinel)"
```

---

### Task 13: Create secret-harbor.yaml and externalsecret-minio.yaml

**Files:**
- Create: `proxy-internet-k8s-service/templates/secret-harbor.yaml`
- Create: `proxy-internet-k8s-service/templates/externalsecret-minio.yaml`

- [ ] **Step 1: Write Harbor secret (same pattern as existing chart)**

```yaml
{{- if not .Values.harbor.existingSecret }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "proxy-internet.fullname" . }}-harbor
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
type: Opaque
stringData:
  HARBOR_USER: {{ .Values.harbor.user | quote }}
  HARBOR_PASS: {{ .Values.harbor.pass | quote }}
{{- end }}
```

- [ ] **Step 2: Write MinIO ExternalSecret (from Vault)**

```yaml
{{- if not .Values.minio.existingSecret }}
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ include "proxy-internet.fullname" . }}-minio
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: {{ include "proxy-internet.fullname" . }}-minio
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: access-key
      remoteRef:
        key: kv/services/minio
        property: access-key
    - secretKey: secret-key
      remoteRef:
        key: kv/services/minio
        property: secret-key
{{- end }}
```

- [ ] **Step 3: Commit**

```bash
git add proxy-internet-k8s-service/templates/secret-harbor.yaml \
        proxy-internet-k8s-service/templates/externalsecret-minio.yaml
git commit -m "feat(k8s-service): add Harbor secret and MinIO ExternalSecret (Vault-backed)"
```

---

### Task 14: Create HPA and PDB resources

**Files:**
- Create: `proxy-internet-k8s-service/templates/hpa-nginx.yaml`
- Create: `proxy-internet-k8s-service/templates/pdb-nginx.yaml`
- Create: `proxy-internet-k8s-service/templates/pdb-redis.yaml`

- [ ] **Step 1: Write HPA with standard + custom metrics**

```yaml
{{- if .Values.hpa.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "proxy-internet.fullname" . }}-nginx
  minReplicas: {{ .Values.hpa.minReplicas }}
  maxReplicas: {{ .Values.hpa.maxReplicas }}
  metrics:
    # Standard CPU
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.metrics.cpu.targetAverageUtilization }}
    # Standard Memory
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.metrics.memory.targetAverageUtilization }}
    {{- if .Values.hpa.metrics.customMetricsEnabled }}
    # Custom metrics below require prometheus-adapter to be configured.
    # See Future Tasks in the plan for prometheus-adapter setup.
    # Set hpa.metrics.customMetricsEnabled=false to use CPU/memory only.
    # Custom: network receive bytes/sec (from cAdvisor via prometheus-adapter)
    - type: Pods
      pods:
        metric:
          name: network_receive_bytes_per_second
        target:
          type: AverageValue
          averageValue: {{ .Values.hpa.metrics.networkRxBytesPerSec.targetValue }}
    # Custom: nginx requests/sec (from nginx-exporter via prometheus-adapter)
    - type: Pods
      pods:
        metric:
          name: nginx_http_requests_per_second
        target:
          type: AverageValue
          averageValue: {{ .Values.hpa.metrics.requestsPerSec.targetValue }}
    # Custom: nginx cache miss rate (from nginx-exporter via prometheus-adapter)
    - type: Pods
      pods:
        metric:
          name: nginx_cache_miss_rate_percent
        target:
          type: AverageValue
          averageValue: {{ .Values.hpa.metrics.cacheMissRate.targetValue }}
    {{- end }}
  behavior:
    scaleUp:
      stabilizationWindowSeconds: {{ .Values.hpa.scaleUp.stabilizationWindowSeconds }}
      policies:
        - type: Pods
          value: {{ .Values.hpa.scaleUp.podCount }}
          periodSeconds: {{ .Values.hpa.scaleUp.periodSeconds }}
    scaleDown:
      stabilizationWindowSeconds: {{ .Values.hpa.scaleDown.stabilizationWindowSeconds }}
      policies:
        - type: Pods
          value: {{ .Values.hpa.scaleDown.podCount }}
          periodSeconds: {{ .Values.hpa.scaleDown.periodSeconds }}
{{- end }}
```

- [ ] **Step 2: Write nginx PDB**

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
spec:
  minAvailable: {{ .Values.pdb.nginx.minAvailable }}
  selector:
    matchLabels:
      {{- include "proxy-internet.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: nginx
```

- [ ] **Step 3: Write Redis PDB**

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "proxy-internet.fullname" . }}-redis
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  minAvailable: {{ .Values.pdb.redis.minAvailable }}
  selector:
    matchLabels:
      app: {{ include "proxy-internet.fullname" . }}-redis
```

- [ ] **Step 4: Verify HPA renders with all metrics**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/hpa-nginx.yaml`
Expected: HPA with 5 metrics (cpu, memory, network, requests, cache miss), scale behavior

- [ ] **Step 5: Commit**

```bash
git add proxy-internet-k8s-service/templates/hpa-nginx.yaml \
        proxy-internet-k8s-service/templates/pdb-nginx.yaml \
        proxy-internet-k8s-service/templates/pdb-redis.yaml
git commit -m "feat(k8s-service): add HPA with custom metrics and PDBs for nginx and Redis"
```

---

## Chunk 5: TLS, Ingress, and Cilium Policies

### Task 15: Create cert-manager resources

**Files:**
- Create: `proxy-internet-k8s-service/templates/cluster-issuer.yaml`
- Create: `proxy-internet-k8s-service/templates/certificate.yaml`

- [ ] **Step 1: Write Vault PKI ClusterIssuer**

```yaml
{{- if .Values.certManager.enabled }}
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: {{ .Values.certManager.issuer.name }}
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
spec:
  vault:
    server: {{ .Values.certManager.vaultPKI.server | quote }}
    path: {{ .Values.certManager.vaultPKI.path | quote }}
    auth:
      kubernetes:
        mountPath: {{ .Values.certManager.vaultPKI.authPath | quote }}
        role: {{ .Values.certManager.vaultPKI.role | quote }}
        serviceAccountRef:
          name: {{ .Values.certManager.vaultPKI.serviceAccountRef | quote }}
{{- end }}
```

- [ ] **Step 2: Write Certificate with all proxy FQDNs**

```yaml
{{- if .Values.certManager.enabled }}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ include "proxy-internet.fullname" . }}-tls
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
spec:
  secretName: {{ .Values.ingress.tls.secretName }}
  issuerRef:
    name: {{ .Values.certManager.issuer.name }}
    kind: {{ .Values.certManager.issuer.kind }}
  duration: {{ .Values.certManager.duration | quote }}
  renewBefore: {{ .Values.certManager.renewBefore | quote }}
  # proxy.aegisgroup.ch is included in SANs for the Cilium egress gateway
  # endpoint — no nginx vhost or IngressRoute exists for it (policy-based only)
  dnsNames:
    {{- $domain := .Values.domain }}
    {{- range list "yum" "apt" "apk" "dl" "charts" "bin" "go" "npm" "pypi" "maven" "crates" "proxy" }}
    - {{ . }}.{{ $domain }}
    {{- end }}
{{- end }}
```

- [ ] **Step 3: Verify SAN list**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/certificate.yaml | grep "aegisgroup"`
Expected: 12 DNS names listed

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/cluster-issuer.yaml \
        proxy-internet-k8s-service/templates/certificate.yaml
git commit -m "feat(k8s-service): add cert-manager Vault PKI issuer and Certificate"
```

---

### Task 16: Create Traefik IngressRoute

**Files:**
- Create: `proxy-internet-k8s-service/templates/ingressroute.yaml`
- Create: `proxy-internet-k8s-service/templates/traefik-service.yaml`

- [ ] **Step 1: Write dedicated Traefik Service (LoadBalancer)**

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "proxy-internet.fullname" . }}-traefik-lb
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: ingress
spec:
  type: LoadBalancer
  loadBalancerIP: {{ .Values.ingress.loadBalancerIP | quote }}
  selector:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/instance: traefik
  ports:
    - name: websecure
      port: 443
      targetPort: websecure
      protocol: TCP
{{- end }}
```

- [ ] **Step 2: Write IngressRoute for all proxy FQDNs**

```yaml
{{- if .Values.ingress.enabled }}
{{- $fullname := include "proxy-internet.fullname" . }}
{{- $domain := .Values.domain }}
{{- $tlsSecret := .Values.ingress.tls.secretName }}
{{- $nginxSvc := printf "%s-nginx" $fullname }}
{{- range list "yum" "apt" "apk" "dl" "charts" "bin" "go" "npm" "pypi" "maven" "crates" }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ $fullname }}-{{ . }}
  labels:
    {{- include "proxy-internet.labels" $ | nindent 4 }}
    app.kubernetes.io/component: ingress
spec:
  entryPoints:
    {{- toYaml $.Values.ingress.entryPoints | nindent 4 }}
  routes:
    - match: Host(`{{ . }}.{{ $domain }}`)
      kind: Rule
      services:
        - name: {{ $nginxSvc }}
          port: 80
  tls:
    secretName: {{ $tlsSecret }}
{{- end }}
{{- end }}
```

- [ ] **Step 3: Verify all 11 IngressRoutes render**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/ingressroute.yaml | grep "kind: IngressRoute" | wc -l`
Expected: 11

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/ingressroute.yaml \
        proxy-internet-k8s-service/templates/traefik-service.yaml
git commit -m "feat(k8s-service): add Traefik IngressRoutes and dedicated LB Service (192.168.48.4)"
```

---

### Task 17: Create Cilium policies

**Files:**
- Create: `proxy-internet-k8s-service/templates/cilium-network-policy.yaml`
- Create: `proxy-internet-k8s-service/templates/cilium-egress-policy.yaml`

- [ ] **Step 1: Write CiliumNetworkPolicy**

```yaml
{{- if .Values.cilium.networkPolicy.enabled }}
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
spec:
  endpointSelector:
    matchLabels:
      {{- include "proxy-internet.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: nginx
  ingress:
    # Allow traffic from Traefik
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: traefik
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    # Allow Prometheus scraping
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: prometheus
      toPorts:
        - ports:
            - port: "9113"
              protocol: TCP
  egress:
    # Allow DNS
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
    # Allow Redis
    - toEndpoints:
        - matchLabels:
            app: {{ include "proxy-internet.fullname" . }}-redis
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
    # Allow MinIO
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: minio
      toPorts:
        - ports:
            - port: "9000"
              protocol: TCP
    # Allow helm-sync service
    - toEndpoints:
        - matchLabels:
            {{- include "proxy-internet.selectorLabels" . | nindent 10 }}
            app.kubernetes.io/component: helm-sync
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
    # Allow upstream internet (HTTPS)
    - toEntities:
        - world
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
            - port: "80"
              protocol: TCP
{{- end }}
```

- [ ] **Step 2: Write CiliumEgressGatewayPolicy (replaces Squid)**

```yaml
{{- if .Values.cilium.egressGateway.enabled }}
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: {{ include "proxy-internet.fullname" . }}-egress
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
spec:
  selectors:
    - podSelector:
        matchLabels:
          {{- include "proxy-internet.selectorLabels" . | nindent 10 }}
          app.kubernetes.io/component: nginx
  destinationCIDRs:
    - "0.0.0.0/0"
  excludedCIDRs:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
  egressGateway:
    nodeSelector:
      matchLabels:
        {{- toYaml .Values.cilium.egressGateway.nodeSelector | nindent 8 }}
    {{- if .Values.cilium.egressGateway.egressIP }}
    egressIP: {{ .Values.cilium.egressGateway.egressIP | quote }}
    {{- end }}
{{- end }}
```

- [ ] **Step 3: Verify policies render**

Run: `helm template test proxy-internet-k8s-service/ --show-only templates/cilium-network-policy.yaml`
Expected: CiliumNetworkPolicy with ingress (traefik, prometheus) and egress (dns, redis, minio, helm-sync, world) rules

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/cilium-network-policy.yaml \
        proxy-internet-k8s-service/templates/cilium-egress-policy.yaml
git commit -m "feat(k8s-service): add Cilium network policy and egress gateway (replaces Squid)"
```

---

## Chunk 6: Observability

### Task 18: Create ServiceMonitors and PrometheusRules

**Files:**
- Create: `proxy-internet-k8s-service/templates/servicemonitor-nginx.yaml`
- Create: `proxy-internet-k8s-service/templates/servicemonitor-redis.yaml`
- Create: `proxy-internet-k8s-service/templates/prometheusrule-alerts.yaml`

- [ ] **Step 1: Write nginx ServiceMonitor**

```yaml
{{- if .Values.monitoring.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "proxy-internet.fullname" . }}-nginx
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
spec:
  selector:
    matchLabels:
      {{- include "proxy-internet.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: nginx
  endpoints:
    - port: metrics
      interval: {{ .Values.monitoring.serviceMonitor.interval }}
      scrapeTimeout: {{ .Values.monitoring.serviceMonitor.scrapeTimeout }}
{{- end }}
```

- [ ] **Step 2: Write Redis ServiceMonitor**

```yaml
{{- if .Values.monitoring.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "proxy-internet.fullname" . }}-redis
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  selector:
    matchLabels:
      app: {{ include "proxy-internet.fullname" . }}-redis
  endpoints:
    - port: redis-exporter
      interval: {{ .Values.monitoring.serviceMonitor.interval }}
      scrapeTimeout: {{ .Values.monitoring.serviceMonitor.scrapeTimeout }}
{{- end }}
```

- [ ] **Step 3: Write PrometheusRule alerts**

```yaml
{{- if .Values.monitoring.prometheusRule.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ include "proxy-internet.fullname" . }}-alerts
  labels:
    {{- include "proxy-internet.labels" . | nindent 4 }}
spec:
  groups:
    - name: proxy-internet.rules
      rules:
        - alert: ProxyHighCacheMissRate
          expr: |
            (rate(nginx_http_requests_total{status=~"2.."}[5m])
            - rate(nginx_http_requests_total{status=~"2..",upstream_cache_status="HIT"}[5m]))
            / rate(nginx_http_requests_total{status=~"2.."}[5m]) > 0.7
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Proxy cache miss rate above 70%"
            description: "Cache miss rate has been above 70% for 10 minutes."
        - alert: ProxyHighErrorRate
          expr: |
            rate(nginx_http_requests_total{status=~"5.."}[5m])
            / rate(nginx_http_requests_total[5m]) > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Proxy error rate above 5%"
            description: "5xx error rate has been above 5% for 5 minutes."
        - alert: ProxyRedisDown
          expr: redis_up == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Redis cache index is down"
            description: "Redis has been unreachable for 2 minutes. Cache index unavailable."
        - alert: ProxyHPAMaxedOut
          expr: |
            kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="{{ include "proxy-internet.fullname" . }}-nginx"}
            == kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler="{{ include "proxy-internet.fullname" . }}-nginx"}
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Proxy HPA at maximum replicas"
            description: "HPA has been at max replicas for 15 minutes. Consider increasing maxReplicas."
{{- end }}
```

- [ ] **Step 4: Commit**

```bash
git add proxy-internet-k8s-service/templates/servicemonitor-nginx.yaml \
        proxy-internet-k8s-service/templates/servicemonitor-redis.yaml \
        proxy-internet-k8s-service/templates/prometheusrule-alerts.yaml
git commit -m "feat(k8s-service): add ServiceMonitors and PrometheusRule alerts"
```

---

## Chunk 7: Final Validation and CI

### Task 19: Full chart validation

- [ ] **Step 1: Run helm lint**

Run: `helm lint proxy-internet-k8s-service/`
Expected: all checks pass

- [ ] **Step 2: Run helm template**

Run: `helm template test proxy-internet-k8s-service/ > /dev/null`
Expected: renders without errors

- [ ] **Step 3: Count all rendered resources**

Run: `helm template test proxy-internet-k8s-service/ | grep "^kind:" | sort | uniq -c | sort -rn`
Expected (approximate): IngressRoute (11), ConfigMap (5), Deployment (2), Service (3+1 LB), HPA (1), PDB (2), Certificate (1), ClusterIssuer (1), CiliumNetworkPolicy (1), CiliumEgressGatewayPolicy (1), RedisReplication (1), RedisSentinel (1), ServiceMonitor (2), PrometheusRule (1), ExternalSecret (1), Secret (1). Some counts may vary based on conditionals.

- [ ] **Step 4: Run yamllint on rendered output**

Run: `helm template test proxy-internet-k8s-service/ | yamllint -d '{extends: default, rules: {line-length: {max: 200}, truthy: {check-keys: false}}}' -`
Expected: clean

- [ ] **Step 5: Commit final state**

```bash
git add proxy-internet-k8s-service/
git commit -m "feat(k8s-service): complete proxy-internet-k8s-service Helm chart

Kubernetes-native internet proxy with:
- nginx (2-5 replicas via HPA) with all 12 vhosts
- nginx-exporter + minio-sync sidecars
- helm-sync separate Deployment
- Redis HA (3 replicas via redis-operator)
- cert-manager + Vault PKI TLS
- Traefik IngressRoutes on dedicated LB (192.168.48.4)
- Cilium network policy + egress gateway
- ServiceMonitors + PrometheusRule alerts
- HPA with CPU/memory/network/request-rate/cache-miss metrics
- PDBs for nginx and Redis"
```

---

### Task 20: Update GitLab CI for new chart

**Files:**
- Modify: `.gitlab-ci.yml`

- [ ] **Step 1: Add helm-lint job for new chart**

Add to the validate stage in `.gitlab-ci.yml`:

```yaml
helm-lint-k8s-service:
  stage: validate
  image: alpine/helm:3.17.1
  script:
    - helm lint proxy-internet-k8s-service/
    - helm template test proxy-internet-k8s-service/ > /dev/null
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

- [ ] **Step 2: Add to argocd-refresh needs list**

Add `helm-lint-k8s-service` to the `needs:` list in the `argocd-refresh` job.

- [ ] **Step 3: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add helm lint job for proxy-internet-k8s-service chart"
```

---

### Task 21: Push to both remotes

- [ ] **Step 1: Push to GitHub**

```bash
git push origin main
```

- [ ] **Step 2: Push to GitLab**

```bash
git push gitlab main
```

- [ ] **Step 3: Verify GitLab pipeline triggers**

```bash
glab api --hostname gitlab.aegisgroup.ch "projects/29/pipelines" | head -5
```

---

## Future Tasks (Not in this plan)

These are documented for follow-up but not implemented in this iteration:

1. **prometheus-adapter ConfigMap** — custom metrics rules for `network_receive_bytes_per_second`, `nginx_http_requests_per_second`, `nginx_cache_miss_rate_percent`. Requires deploying prometheus-adapter if not already present.
2. **Vault PKI engine setup** — enable PKI secrets engine, import Root CA, create role `proxy-internet`. Prerequisite for cert-manager to work.
3. **MinIO bucket lifecycle policy** — configure 30-day expiry on `proxy-cache` bucket.
4. **Grafana dashboards** — `dashboards/proxy-overview.json` with cache hit/miss, bandwidth, HPA, Redis panels.
5. **Loki structured logging** — ensure Promtail/Grafana Agent picks up nginx JSON logs from pods.
6. **Hubble → Loki pipeline** — configure Hubble flow log export to Loki for egress visibility.
7. **minio-sync hardening** — replace `mc mirror` polling with inotifywait-based event-driven sync.
8. **Redis index population** — init container or startup script that scans MinIO bucket to rebuild Redis index.
