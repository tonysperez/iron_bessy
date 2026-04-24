packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "vm_id" {
  description = "Proxmox VM ID for the resulting template. Must be unique across all templates."
  type        = number
  default     = 991
}

variable "vm_boot_iso" {
  description = "Path to the Ubuntu ISO in Proxmox storage (e.g. local:iso/ubuntu-24.04-live-server-amd64.iso)."
  type        = string
  default     = "local:iso/ubuntu-24.04.4-live-server-amd64.iso"
}

variable "vm_boot_iso_hash" {
  description = "SHA256 checksum of the boot ISO for integrity verification."
  type        = string
  default     = "sha256:e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  buildtime = formatdate("YYYY-MM-DD", timestamp())
  userdata  = templatefile("./cloudinit/user-data.pkrtpl", {
    username            = var.template_username
    password_hash       = bcrypt(var.template_password)
    ansible_username    = var.ansible_username
    ansible_ssh_key     = var.ansible_ssh_key
    breakglass_username = var.breakglass_username
    breakglass_ssh_key  = var.breakglass_ssh_key
  })
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------

source "proxmox-iso" "ubuntu-2404-core" {
  # Proxmox Connection Settings
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  # WARNING: insecure_skip_tls_verify is set for homelab with self-signed certs.
  # For production, use proper certificates and set this to false.
  insecure_skip_tls_verify = true

  # VM General Settings
  vm_id                = var.vm_id
  vm_name              = "template-ubuntu-2404-server-core"
  template_description = "Ubuntu 24.04 Server Template, built with Packer on ${local.buildtime}"

  # Set Proxmox Resource Pool
  pool = var.proxmox_vm_pool

  # VM ISO Settings
  boot_iso {
    type              = "ide"
    iso_file          = var.vm_boot_iso
    unmount           = true
    keep_cdrom_device = false
    iso_checksum      = var.vm_boot_iso_hash
  }

  # Explicitly set boot order to prefer virtio0 (installed disk) over ide devices
  boot = "order=virtio0;ide0"

  # VM System Settings
  os           = "l26"
  machine      = "q35"
  memory       = 2048
  cores        = 2
  sockets      = 1
  cpu_type     = "x86-64-v2-AES"
  qemu_agent   = true
  task_timeout = "20m"

  vga {
    type = "qxl"
  }

  # VM Hard Disk Settings
  scsi_controller = "virtio-scsi-single"

  disks {
    disk_size    = "30G"
    format       = "raw"
    storage_pool = var.proxmox_vm_storage_pool
    type         = "virtio"
    discard      = true
    io_thread    = true
  }

  bios = "ovmf"
  efi_config {
    efi_storage_pool  = var.proxmox_vm_storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = true
  }

  # VM Network Settings
  network_adapters {
    model    = "virtio"
    bridge   = var.vm_network_bridge
    vlan_tag = var.vm_network_vlan
    firewall = true
  }

  # VM Cloud-Init Settings
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_vm_storage_pool

  # Cloud-init config via additional ISO
  additional_iso_files {
    type              = "ide"
    index             = 1
    iso_storage_pool  = var.proxmox_iso_storage_pool
    unmount           = true
    keep_cdrom_device = false
    cd_content = {
      "meta-data" = file("./cloudinit/meta-data")
      "user-data" = local.userdata
    }
    cd_label = "cidata"
  }

  # Ubuntu Subiquity Installer Boot Sequence
  # This sequence bypasses the interactive menu and enables unattended installation.
  # Steps:
  # 1. <esc>: Enter boot menu editor
  # 2. e: Edit the boot command
  # 3. <down><down><down><end>: Navigate to end of kernel command line
  # 4. Append autoinstall flags (ds=nocloud to use cloud-init ISO)
  # 5. <f10>: Boot with modified parameters
  boot_wait = "10s"
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    " autoinstall quiet ds=nocloud",
    "<f10>"
  ]

  # Communicator Settings
  ssh_username = var.template_username
  ssh_password = var.template_password
  ssh_timeout  = "30m"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build {
  name    = "ubuntu-2404-core"
  sources = ["source.proxmox-iso.ubuntu-2404-core"]

  # Wait for cloud-init, enable guest agent, remove installer networking artefacts
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 10; done",
      "sudo systemctl enable qemu-guest-agent",
      "sudo systemctl start qemu-guest-agent",
      "sudo cloud-init clean",
      "sudo rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg",
      "sudo rm -f /etc/netplan/00-installer-config.yaml",
      "echo \"Ubuntu 24.04 Template by Packer - Creation Date: $(date)\" | sudo tee /etc/issue"
    ]
  }

  # Update packages
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get autoremove -y"
    ]
  }

  # Eject ISOs, set boot device, and reset cloud-init for first-boot provisioning
  provisioner "shell" {
    expect_disconnect = true
    inline = [
      "sudo eject /dev/sr0 || true",
      "sudo eject /dev/sr1 || true",
      "sudo sed -i '/cdrom/d' /etc/fstab",
      "sudo sync",
      "sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub",
      "sudo update-grub",
      "sudo cloud-init clean --logs"
    ]
  }

  # Lock the build-time user account. It cannot be deleted while Packer is
  # connected as that user. Downstream provisioning should remove it entirely.
  provisioner "shell" {
    inline = [
      "sudo passwd -l ${var.template_username}",
      "sudo rm -f /etc/sudoers.d/${var.template_username}"
    ]
  }

}
