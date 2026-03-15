# -----------------------------------------------------------------------------
# Harvester Connection
# -----------------------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  description = "Path to Harvester cluster kubeconfig"
  type        = string
}

# -----------------------------------------------------------------------------
# VM Configuration
# -----------------------------------------------------------------------------

variable "vm_namespace" {
  description = "Harvester namespace where the VM will be created"
  type        = string
  default     = "default"
}

variable "vm_name" {
  description = "Name of the airgap proxy VM"
  type        = string
  default     = "airgap-proxy"
}

variable "cpu" {
  description = "Number of vCPUs"
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory size (Kubernetes quantity)"
  type        = string
  default     = "4Gi"
}

variable "os_disk_size" {
  description = "OS disk size (Kubernetes quantity)"
  type        = string
  default     = "100Gi"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "network_name" {
  description = "Harvester VM network in namespace/name format"
  type        = string
  default     = "default/vm-network"
}

variable "static_ip" {
  description = "Static IP address for the VM"
  type        = string
}

variable "gateway" {
  description = "Default gateway IP"
  type        = string
  default     = "10.0.0.1"
}

variable "dns_server" {
  description = "DNS server IP"
  type        = string
  default     = "10.0.0.1"
}

variable "cidr_prefix" {
  description = "Network CIDR prefix length"
  type        = number
  default     = 24
}

# -----------------------------------------------------------------------------
# SSH
# -----------------------------------------------------------------------------

variable "ssh_user" {
  description = "SSH user for the cloud image"
  type        = string
  default     = "rocky"
}

variable "ssh_authorized_keys" {
  description = "List of SSH public keys to add to the VM"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Image
# -----------------------------------------------------------------------------

variable "image_name" {
  description = "Existing Harvester image name to use (namespace/name format)"
  type        = string
  default     = "default/dev-vm-rocky9"
}

# -----------------------------------------------------------------------------
# Domain
# -----------------------------------------------------------------------------

variable "domain" {
  description = "Base domain for proxy hostnames"
  type        = string
  default     = "example.com"
}

# -----------------------------------------------------------------------------
# Harbor (for helm-sync)
# -----------------------------------------------------------------------------

variable "harbor_host" {
  description = "Harbor registry hostname"
  type        = string
  default     = "harbor.example.com"
}

variable "harbor_user" {
  description = "Harbor robot account username"
  type        = string
  default     = ""
}

variable "harbor_pass" {
  description = "Harbor robot account password"
  type        = string
  sensitive   = true
  default     = ""
}
