# -----------------------------------------------------------------------------
# Cloud-Init: Network (static IP)
# -----------------------------------------------------------------------------

locals {
  network_data = join("\n", [
    "#cloud-config",
    yamlencode({
      network = {
        version = 2
        ethernets = {
          eth0 = {
            addresses = ["${var.static_ip}/${var.cidr_prefix}"]
            gateway4  = var.gateway
            nameservers = {
              addresses = [var.dns_server]
            }
          }
        }
      }
    }),
  ])

  proxy_hostnames = "yum.${var.domain} apt.${var.domain} apk.${var.domain} dl.${var.domain} charts.${var.domain} bin.${var.domain} go.${var.domain} npm.${var.domain} pypi.${var.domain} maven.${var.domain} crates.${var.domain} harbor.${var.domain} proxy.${var.domain}"

  # Inline all nginx/registry configs as write_files entries
  write_files = concat(
    [
      # /etc/hosts — proxy hostnames resolve to self
      {
        path    = "/etc/cloud/templates/hosts.debian.tmpl"
        content = "# Managed by cloud-init\n127.0.0.1 localhost\n127.0.0.1 ${var.vm_name}\n127.0.0.1 ${local.proxy_hostnames}\n"
      },
      # Docker compose
      {
        path    = "/opt/airgap/docker-compose.yaml"
        content = file("${path.module}/../docker-compose.yaml")
      },
      # nginx main config
      {
        path    = "/opt/airgap/nginx/nginx.conf"
        content = file("${path.module}/../nginx/nginx.conf")
      },
      # nginx includes
      {
        path    = "/opt/airgap/nginx/includes/ssl-defaults.conf"
        content = file("${path.module}/../nginx/includes/ssl-defaults.conf")
      },
      {
        path    = "/opt/airgap/nginx/includes/proxy-defaults.conf"
        content = file("${path.module}/../nginx/includes/proxy-defaults.conf")
      },
      {
        path    = "/opt/airgap/nginx/includes/cache.conf"
        content = file("${path.module}/../nginx/includes/cache.conf")
      },
      # nginx vhosts
      {
        path    = "/opt/airgap/nginx/conf.d/yum.conf"
        content = file("${path.module}/../nginx/conf.d/yum.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/apt.conf"
        content = file("${path.module}/../nginx/conf.d/apt.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/dl.conf"
        content = file("${path.module}/../nginx/conf.d/dl.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/charts.conf"
        content = file("${path.module}/../nginx/conf.d/charts.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/bin.conf"
        content = file("${path.module}/../nginx/conf.d/bin.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/apk.conf"
        content = file("${path.module}/../nginx/conf.d/apk.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/go.conf"
        content = file("${path.module}/../nginx/conf.d/go.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/npm.conf"
        content = file("${path.module}/../nginx/conf.d/npm.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/pypi.conf"
        content = file("${path.module}/../nginx/conf.d/pypi.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/maven.conf"
        content = file("${path.module}/../nginx/conf.d/maven.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/crates.conf"
        content = file("${path.module}/../nginx/conf.d/crates.conf")
      },
      {
        path    = "/opt/airgap/nginx/conf.d/harbor.conf"
        content = file("${path.module}/../nginx/conf.d/harbor.conf")
      },
      # Squid forward proxy
      {
        path    = "/opt/airgap/squid/squid.conf"
        content = file("${path.module}/../squid/squid.conf")
      },
      # Helm OCI charts manifest
      {
        path    = "/opt/airgap/helm-oci/charts.manifest"
        content = file("${path.module}/../helm-oci/charts.manifest")
      },
      # docker-compose .env
      {
        path    = "/opt/airgap/.env"
        content = "HARBOR_HOST=${var.harbor_host}\nHARBOR_USER=${var.harbor_user}\nHARBOR_PASS=${var.harbor_pass}\n"
      },
      # helm-sync build context
      {
        path    = "/opt/airgap/helm-sync/Dockerfile"
        content = file("${path.module}/../helm-sync/Dockerfile")
      },
      {
        path        = "/opt/airgap/helm-sync/helm-sync.sh"
        content     = file("${path.module}/../helm-sync/helm-sync.sh")
        permissions = "0755"
      },
      {
        path        = "/opt/airgap/helm-sync/entrypoint.sh"
        content     = file("${path.module}/../helm-sync/entrypoint.sh")
        permissions = "0755"
      },
      # Registry config
      {
        path    = "/opt/airgap/registry/config.yml"
        content = file("${path.module}/../registry/config.yml")
      },
      # Docker daemon config — keep Docker networks out of 172.16-18.x.x
      {
        path        = "/etc/docker/daemon.json"
        permissions = "0644"
        content     = jsonencode({
          bip                  = "172.100.10.1/24"
          "fixed-cidr"         = "172.100.10.0/24"
          "default-address-pools" = [{ base = "172.100.0.0/16", size = 24 }]
          "log-driver"         = "json-file"
          "log-opts"           = { "max-size" = "50m", "max-file" = "3" }
        })
      },
    ],
    # Certs (only if they exist — plan will fail if they don't)
    [
      {
        path        = "/opt/airgap/certs/server-fullchain.pem"
        content     = file("${path.module}/../certs/server-fullchain.pem")
        permissions = "0644"
      },
      {
        path        = "/opt/airgap/certs/server-key.pem"
        content     = file("${path.module}/../certs/server-key.pem")
        permissions = "0600"
      },
      {
        path        = "/opt/airgap/certs/ca-chain.pem"
        content     = file("${path.module}/../certs/ca-chain.pem")
        permissions = "0644"
      },
      # Install CA into system trust
      {
        path        = "/etc/pki/ca-trust/source/anchors/airgap-proxy-ca.pem"
        content     = file("${path.module}/../certs/ca-chain.pem")
        permissions = "0644"
      },
    ],
  )

  user_data = join("\n", [
    "#cloud-config",
    yamlencode({
      hostname         = var.vm_name
      manage_etc_hosts = false
      package_update   = true

      ssh_authorized_keys = var.ssh_authorized_keys

      packages = [
        "qemu-guest-agent",
        "dnf-plugins-core",
        "curl",
        "jq",
      ]

      write_files = local.write_files

      runcmd = [
        # Guest agent
        "dnf install -y qemu-guest-agent",
        "systemctl enable --now qemu-guest-agent",

        # /etc/hosts — proxy hostnames resolve to self
        "grep -q 'yum.${var.domain}' /etc/hosts || echo '127.0.0.1 ${local.proxy_hostnames}' >> /etc/hosts",

        # Trust private CA
        "update-ca-trust",

        # Install Docker
        "dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
        "dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin",
        "systemctl enable --now docker",
        "usermod -aG docker ${var.ssh_user}",

        # Create bin/data directory (empty — will be populated via scp)
        "mkdir -p /opt/airgap/bin/data",

        # Replace example.com with actual domain in nginx vhost configs
        "find /opt/airgap/nginx/conf.d -name '*.conf' -exec sed -i 's/example\\.com/${var.domain}/g' {} +",

        # Build helm-sync image
        "mkdir -p /opt/airgap/helm-sync",

        # Start the compose stack
        "cd /opt/airgap && docker compose up -d",
      ]
    }),
  ])
}

# -----------------------------------------------------------------------------
# Cloud-Init Secrets
# -----------------------------------------------------------------------------

resource "harvester_cloudinit_secret" "airgap_proxy" {
  name      = "${var.vm_name}-cloudinit"
  namespace = var.vm_namespace

  user_data    = local.user_data
  network_data = local.network_data
}

# -----------------------------------------------------------------------------
# Airgap Proxy VM
# -----------------------------------------------------------------------------

resource "harvester_virtualmachine" "airgap_proxy" {
  name                 = var.vm_name
  namespace            = var.vm_namespace
  restart_after_update = true

  description = "Airgap simulation proxy — nginx reverse proxy + Docker registry"

  cpu    = var.cpu
  memory = var.memory

  efi         = true
  secure_boot = false

  run_strategy = "RerunOnFailure"

  machine_type = "q35"

  network_interface {
    name           = "nic-1"
    network_name   = var.network_name
    wait_for_lease = true
  }

  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = var.os_disk_size
    bus        = "virtio"
    boot_order = 1
    image      = var.image_name
  }

  cloudinit {
    user_data_secret_name    = harvester_cloudinit_secret.airgap_proxy.name
    network_data_secret_name = harvester_cloudinit_secret.airgap_proxy.name
  }

  timeouts {
    create = "30m"
  }
}
