# Proxmox Connection
variable "proxmox_url" {
  description = "URL of the Proxmox API endpoint (e.g. https://proxmox.example.com:8006/api2/json)."
  type        = string
}

variable "proxmox_node" {
  description = "Name of the Proxmox node to build the template on."
  type        = string
}

# Proxmox Credentials
variable "proxmox_username" {
  description = "Proxmox username for API authentication (e.g. packer@pve!token-name)."
  type        = string
  sensitive   = true
}

variable "proxmox_token" {
  description = "Proxmox API token secret for the configured user."
  type        = string
  sensitive   = true
}

# Proxmox Storage
variable "proxmox_vm_storage_pool" {
  description = "Proxmox storage pool for VM disk, EFI, and cloud-init drives."
  type        = string
}

variable "proxmox_iso_storage_pool" {
  description = "Proxmox storage pool where ISOs are located."
  type        = string
}

variable "proxmox_vm_pool" {
  description = "Proxmox resource pool to assign the build VM to."
  type        = string
}

# Proxmox Network
variable "vm_network_bridge" {
  description = "Proxmox network bridge to attach the build VM to."
  type        = string
}

variable "vm_network_vlan" {
  description = "VLAN tag for the build VM network interface."
  type        = number
}

# Template Credentials (Packer build user)
variable "template_username" {
  description = "Username Packer uses to remote into the build VM. Must match the identity in cloudinit/user-data."
  type        = string
}

variable "template_password" {
  description = "Password Packer uses to remote into the build VM."
  type        = string
  sensitive   = true
}

# Pipeline Accounts (baked into every image at build time)
variable "ansible_username" {
  description = "Username for the Ansible service account."
  type        = string
}

variable "ansible_ssh_key" {
  description = "SSH public key injected into the Ansible service account at build time."
  type        = string
  sensitive   = true
}

variable "breakglass_username" {
  description = "Username for the break-glass emergency account."
  type        = string
}

variable "breakglass_ssh_key" {
  description = "SSH public key injected into the break-glass emergency account at build time."
  type        = string
  sensitive   = true
}
