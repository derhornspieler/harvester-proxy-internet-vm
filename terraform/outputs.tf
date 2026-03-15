output "vm_ip" {
  description = "Static IP of the airgap proxy VM"
  value       = var.static_ip
}

output "vm_name" {
  description = "Name of the airgap proxy VM"
  value       = harvester_virtualmachine.airgap_proxy.name
}

output "proxy_hostnames" {
  description = "Proxy hostnames to add to DNS/hosts"
  value = [
    "yum.${var.domain}",
    "apt.${var.domain}",
    "apk.${var.domain}",
    "dl.${var.domain}",
    "charts.${var.domain}",
    "bin.${var.domain}",
    "go.${var.domain}",
    "npm.${var.domain}",
    "pypi.${var.domain}",
    "maven.${var.domain}",
    "crates.${var.domain}",
    "harbor.${var.domain}",
    "proxy.${var.domain}",
  ]
}

output "registry_url" {
  description = "Bootstrap registry URL"
  value       = "${var.static_ip}:5000"
}

output "squid_proxy" {
  description = "Squid forward proxy URL"
  value       = "http://${var.static_ip}:3128"
}

output "hosts_entry" {
  description = "/etc/hosts line for clients"
  value       = "${var.static_ip}  yum.${var.domain} apt.${var.domain} apk.${var.domain} dl.${var.domain} charts.${var.domain} bin.${var.domain} go.${var.domain} npm.${var.domain} pypi.${var.domain} maven.${var.domain} crates.${var.domain} harbor.${var.domain} proxy.${var.domain}"
}
