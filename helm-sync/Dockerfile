FROM alpine:3.21

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        nmap-ncat \
    && ARCH="$(uname -m)" \
    && case "$ARCH" in \
        x86_64)  HELM_ARCH="amd64" ;; \
        aarch64) HELM_ARCH="arm64" ;; \
        *)       echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac \
    && curl -fsSL "https://get.helm.sh/helm-v3.17.1-linux-${HELM_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin --strip-components=1 "linux-${HELM_ARCH}/helm" \
    && helm version --short

COPY helm-sync.sh /opt/helm-sync/helm-sync.sh
COPY entrypoint.sh /opt/helm-sync/entrypoint.sh
RUN chmod +x /opt/helm-sync/helm-sync.sh /opt/helm-sync/entrypoint.sh \
    && mkdir -p /var/log/helm-sync /tmp/helm-sync-locks

EXPOSE 8888

ENTRYPOINT ["/opt/helm-sync/entrypoint.sh"]
