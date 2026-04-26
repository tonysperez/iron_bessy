# ---------------------------------------------------------------------------
# Inventory output for downstream tooling (Ansible, etc.)
# Consumed by the console to write console/pipeline/inventory.json after apply.
# Add each new VM type to the merge() below as new images are introduced.
# ---------------------------------------------------------------------------

locals {
  inventory = merge(
    {
      for name, vm in proxmox_virtual_environment_vm.ubuntu_server_2404_core_vms :
      name => {
        vm_id    = vm.vm_id
        node     = vm.node_name
        image    = "ubuntu-server-2404-core"
        ssh_user = var.ansible_username
        tags     = vm.tags
        vlan     = local.ubuntu_server_2404_core_resolved[name].vlan
        # Static IP (CIDR stripped) if defined; otherwise the first non-loopback
        # address reported by the QEMU guest agent. bpg/proxmox returns
        # ipv4_addresses as a list-of-lists indexed by NIC, with index 0 the
        # loopback interface — so [1][0] is the first IP on the first real NIC.
        # Null if the agent has not yet reported.
        ip_address = (
          local.ubuntu_server_2404_core_resolved[name].ip_address != null
          ? split("/", local.ubuntu_server_2404_core_resolved[name].ip_address)[0]
          : try(vm.ipv4_addresses[1][0], null)
        )
      }
    },
    
    {
      for name, vm in proxmox_virtual_environment_vm.ubuntu_server_2004_core_vms :
      name => {
        vm_id    = vm.vm_id
        node     = vm.node_name
        image    = "ubuntu-server-2004-core"
        ssh_user = var.ansible_username
        tags     = vm.tags
        vlan     = local.ubuntu_server_2004_core_resolved[name].vlan
        # Static IP (CIDR stripped) if defined; otherwise the first non-loopback
        # address reported by the QEMU guest agent. bpg/proxmox returns
        # ipv4_addresses as a list-of-lists indexed by NIC, with index 0 the
        # loopback interface — so [1][0] is the first IP on the first real NIC.
        # Null if the agent has not yet reported.
        ip_address = (
          local.ubuntu_server_2004_core_resolved[name].ip_address != null
          ? split("/", local.ubuntu_server_2004_core_resolved[name].ip_address)[0]
          : try(vm.ipv4_addresses[1][0], null)
        )
      }
    }

  ) 
}

output "vms" {
  description = "Map of all provisioned VMs and their attributes, keyed by VM name."
  value       = local.inventory
}
