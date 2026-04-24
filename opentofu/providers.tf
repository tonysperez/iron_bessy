terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.102.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_url
  api_token = "${var.proxmox_username}=${var.proxmox_token}"
  # WARNING: insecure is set for homelab with self-signed certs.
  # For production, use proper certificates and set this to false.
  insecure = true
}
