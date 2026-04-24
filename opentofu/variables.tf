# ---------------------------------------------------------------------------
# Proxmox Connection
# ---------------------------------------------------------------------------

variable "proxmox_url" {
  description = "URL of the Proxmox API endpoint (e.g. https://proxmox.example.com:8006)."
  type        = string
}

variable "proxmox_node" {
  description = "Name of the Proxmox node to provision VMs on."
  type        = string
}

# ---------------------------------------------------------------------------
# Proxmox Credentials
# ---------------------------------------------------------------------------

variable "proxmox_username" {
  description = "Proxmox username for API authentication (e.g. terraform@pve!terraform-token)."
  type        = string
  sensitive   = true
}

variable "proxmox_token" {
  description = "Proxmox API token secret for the configured user."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Proxmox Storage and Network
# ---------------------------------------------------------------------------

variable "proxmox_vm_storage_pool" {
  description = "Proxmox storage pool used for VM disks and cloud-init drives."
  type        = string
}

variable "vm_network_bridge" {
  description = "Proxmox network bridge to attach VM network interfaces to."
  type        = string
}

# ---------------------------------------------------------------------------
# Cluster-Scoped Network Defaults
# Fallbacks used by VMs that do not specify the corresponding field. Set by the
# console (cached per cluster). Each is optional, leave null to require the
# field on every VM.
# ---------------------------------------------------------------------------

variable "vm_default_vlan" {
  description = "Default VLAN tag for VMs that do not specify one."
  type        = number
  default     = null

  validation {
    condition     = var.vm_default_vlan == null || (var.vm_default_vlan >= 1 && var.vm_default_vlan <= 4094)
    error_message = "vm_default_vlan must be between 1 and 4094, or null."
  }
}

variable "vm_default_gateway" {
  description = "Default IPv4 gateway for VMs that do not specify one."
  type        = string
  default     = null

  validation {
    condition     = var.vm_default_gateway == null || can(cidrhost("${var.vm_default_gateway}/32", 0))
    error_message = "vm_default_gateway must be a valid IPv4 address, or null."
  }
}

variable "vm_default_dns_servers" {
  description = "Default DNS servers for VMs that do not specify any."
  type        = list(string)
  default     = null

  validation {
    condition     = var.vm_default_dns_servers == null || alltrue([for s in var.vm_default_dns_servers : can(cidrhost("${s}/32", 0))])
    error_message = "Each entry in vm_default_dns_servers must be a valid IPv4 address."
  }
}

variable "vm_default_dns_domain" {
  description = "Default DNS search domain for VMs that do not specify one."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Pipeline Accounts
# ---------------------------------------------------------------------------

variable "ansible_username" {
  description = "Username of the Ansible service account baked into the template by Packer. Used in inventory output so downstream tooling knows which user to SSH as."
  type        = string
  default     = "ansible"
}

# ---------------------------------------------------------------------------
# Pipeline Inputs
# ---------------------------------------------------------------------------

variable "template_vm_ids" {
  description = "Map of pipeline image name to Proxmox VMID. Populated from the pipeline manifest by the console."
  type        = map(number)
}

variable "group_deps" {
  description = "Groups that must be applied before this one. Read by the iron_bessy console to enforce ordering; not used by OpenTofu infrastructure."
  type        = list(string)
  default     = []
}

variable "vm_pool" {
  description = "Optional Proxmox resource pool to place provisioned VMs in. Empty string or null means no pool."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Cluster Firewall
# ---------------------------------------------------------------------------

variable "firewall_security_groups" {
  description = "Map of Proxmox cluster-level firewall security groups and their rules."
  type = map(object({
    comment = optional(string, "")

    rules = list(object({
      type    = string
      action  = string
      comment = optional(string, "")
      source  = optional(string)
      sport   = optional(string)
      dest    = optional(string)
      dport   = optional(string)
      proto   = optional(string)
      log     = optional(string, "nolog")
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, sg in var.firewall_security_groups : alltrue([
        for rule in sg.rules : contains(["in", "out"], rule.type)
      ])
    ])
    error_message = "Firewall rule type must be \"in\" or \"out\"."
  }

  validation {
    condition = alltrue([
      for name, sg in var.firewall_security_groups : alltrue([
        for rule in sg.rules : contains(["ACCEPT", "DROP", "REJECT"], rule.action)
      ])
    ])
    error_message = "Firewall rule action must be \"ACCEPT\", \"DROP\", or \"REJECT\"."
  }

  validation {
    condition = alltrue([
      for name, sg in var.firewall_security_groups : alltrue([
        for rule in sg.rules : contains(["nolog", "info", "warning", "err", "crit", "alert", "emerg", "debug"], rule.log)
      ])
    ])
    error_message = "Firewall rule log must be one of: nolog, info, warning, err, crit, alert, emerg, debug."
  }
}

# ---------------------------------------------------------------------------
# VM Definitions
# ---------------------------------------------------------------------------

variable "ubuntu_server_2404_core_vms" {
  description = "Ubuntu Server 24.04 Core VMs to provision. Cloned from the ubuntu-server-2404-core pipeline image."
  type = map(object({
    ip_address         = optional(string)
    ip_gateway         = optional(string)
    dns_servers        = optional(list(string))
    dns_domain         = optional(string)
    vlan               = optional(number)
    cores              = number
    memory             = number
    disk_size          = optional(number, 30)
    ssd                = optional(bool, false)
    discard            = optional(bool, false)
    fw_security_group  = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, vm in var.ubuntu_server_2404_core_vms :
      vm.vlan == null || (vm.vlan >= 1 && vm.vlan <= 4094)
    ])
    error_message = "Each VM's vlan must be between 1 and 4094, or null."
  }

  validation {
    condition = alltrue([
      for name, vm in var.ubuntu_server_2404_core_vms :
      vm.ip_address == null || can(cidrhost(vm.ip_address, 0))
    ])
    error_message = "Each VM's ip_address must be a valid IPv4 CIDR (e.g. 192.168.1.10/24), or null for DHCP."
  }

  validation {
    condition = alltrue([
      for name, vm in var.ubuntu_server_2404_core_vms :
      vm.ip_gateway == null || can(cidrhost("${vm.ip_gateway}/32", 0))
    ])
    error_message = "Each VM's ip_gateway must be a valid IPv4 address, or null."
  }

  validation {
    condition = alltrue([
      for name, vm in var.ubuntu_server_2404_core_vms :
      vm.dns_servers == null || alltrue([for s in vm.dns_servers : can(cidrhost("${s}/32", 0))])
    ])
    error_message = "Each VM's dns_servers entries must be valid IPv4 addresses."
  }
}
