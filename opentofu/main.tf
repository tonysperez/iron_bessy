# ---------------------------------------------------------------------------
# Cluster Firewall Security Groups
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_cluster_firewall_security_group" "groups" {
  for_each = var.firewall_security_groups

  name    = each.key
  comment = each.value.comment

  dynamic "rule" {
    for_each = each.value.rules

    content {
      type    = rule.value.type
      action  = rule.value.action
      comment = rule.value.comment
      source  = rule.value.source
      sport   = rule.value.sport
      dest    = rule.value.dest
      dport   = rule.value.dport
      proto   = rule.value.proto
      log     = rule.value.log
    }
  }
}

# ---------------------------------------------------------------------------
# Ubuntu Server 24.04 Core VMs
# ---------------------------------------------------------------------------

# Per-VM values merged with cluster-scoped defaults so each field is resolved
# exactly once. Consumed by the resource below and by outputs.tf.
locals {
  ubuntu_server_2404_core_resolved = {
    for name, vm in var.ubuntu_server_2404_core_vms : name => merge(vm, {
      vlan        = vm.vlan != null ? vm.vlan : var.vm_default_vlan
      ip_gateway  = vm.ip_gateway != null ? vm.ip_gateway : var.vm_default_gateway
      dns_servers = vm.dns_servers != null ? vm.dns_servers : var.vm_default_dns_servers
      dns_domain  = vm.dns_domain != null ? vm.dns_domain : var.vm_default_dns_domain
    })
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_server_2404_core_vms" {
  for_each = local.ubuntu_server_2404_core_resolved

  name        = each.key
  description = "Cloned from ubuntu-server-2404-core, managed by OpenTofu"
  tags        = ["opentofu", lower(terraform.workspace)]
  node_name   = var.proxmox_node
  pool_id     = var.vm_pool

  clone {
    vm_id = var.template_vm_ids["ubuntu-server-2404-core"]
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  network_device {
    bridge   = var.vm_network_bridge
    vlan_id  = each.value.vlan
    firewall = true
  }

  disk {
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    datastore_id = var.proxmox_vm_storage_pool
    ssd          = each.value.ssd
    discard      = each.value.discard ? "on" : "ignore"
  }

  lifecycle {
    ignore_changes = [initialization]
  }

  # Cloud-init applied on first boot only.
  # Changes here have no effect on already-provisioned VMs (see lifecycle.ignore_changes).
  initialization {
    datastore_id = var.proxmox_vm_storage_pool

    ip_config {
      ipv4 {
        address = each.value.ip_address != null ? each.value.ip_address : "dhcp"
        gateway = each.value.ip_gateway
      }
    }

    # DNS block is omitted entirely if neither servers nor domain resolve.
    dynamic "dns" {
      for_each = anytrue([
        each.value.dns_servers != null,
        each.value.dns_domain != null,
      ]) ? [1] : []
      content {
        servers = each.value.dns_servers
        domain  = each.value.dns_domain
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Locals: VM Aggregations
# ---------------------------------------------------------------------------

locals {
  # Merge every VM type's resolved map into a flat map for firewall iteration.
  # Add each new VM type's `<image>_resolved` local here as new images are introduced.
  all_vms = merge(
    local.ubuntu_server_2404_core_resolved,
  )

  # Merge post-provision VM IDs from all resources for firewall rule attachment.
  # Add each new VM type resource here alongside its resolved local.
  vm_ids = merge(
    { for k, v in proxmox_virtual_environment_vm.ubuntu_server_2404_core_vms : k => v.vm_id },
  )
}

# ---------------------------------------------------------------------------
# Per-VM Firewall
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_firewall_options" "vm_firewall" {
  depends_on = [proxmox_virtual_environment_firewall_rules.security_groups]

  for_each = {
    for vm_name, vm in local.all_vms :
    vm_name => vm
    if vm.fw_security_group != null
  }

  node_name = var.proxmox_node
  vm_id     = local.vm_ids[each.key]
  enabled   = true
}

resource "proxmox_virtual_environment_firewall_rules" "security_groups" {
  depends_on = [proxmox_virtual_environment_cluster_firewall_security_group.groups]

  for_each = {
    for vm_name, vm in local.all_vms :
    vm_name => vm
    if vm.fw_security_group != null
  }

  vm_id     = local.vm_ids[each.key]
  node_name = var.proxmox_node

  rule {
    security_group = each.value.fw_security_group
  }
}
