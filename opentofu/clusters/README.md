# opentofu/clusters

Per-cluster, per-group OpenTofu variable definitions. Each subdirectory is a cluster; each
`.tfvars` file inside it is a group. The console selects both when provisioning infrastructure.

## Layout

```
clusters/
└── <cluster-name>/
    ├── <group>.tfvars       # VM definitions and/or firewall groups for this group
    └── <group>.tfvars       # another group in the same cluster
```

## Groups

Each `.tfvars` file is a selectable group in the console. Groups within a cluster share the
same Proxmox cluster but have fully isolated OpenTofu state (`terraform.tfstate.d/<cluster>-<group>/`).
Destroying one group never touches another.

A group file can define any combination of:

- **VM definitions** (`ubuntu_server_2404_core_vms`) — VMs to provision by cloning a Packer template
- **Firewall security groups** (`firewall_security_groups`) — cluster-level Proxmox firewall groups

**Keep shared infrastructure in its own group.** Firewall security groups are cluster-wide
Proxmox resources. If multiple VM groups reference the same security group by name, only one
group should own and manage it. Destroying the owner group will remove the firewall group from
Proxmox, which may affect VMs in other groups.

## Group Dependencies

Declare dependencies between groups inline in the `.tfvars` file:

```hcl
group_deps = ["fw"]
```

The console reads this and blocks Apply until each listed group has applied state. Destroy is
blocked in the reverse direction: you cannot destroy a group while another group that depends
on it has applied state.

`group_deps` is consumed by the console only — OpenTofu itself ignores it.

## Example

```
clusters/
└── homelab/
    ├── fw.tfvars      # owns firewall security groups; no deps
    └── dshield.tfvars       # owns VMs; depends on range_fw
```

`dshield.tfvars`:
```hcl
group_deps = ["fw"]

ubuntu_server_2404_core_vms = {
  "web01" = {
    cores             = 2
    memory            = 4096
    ip_address        = "192.168.0.69/24"
    ip_gateway        = "192.168.0.1"
    vlan              = 10
    fw_security_group = "block_outbound_private"
  }
}
```

`fw.tfvars`:
```hcl
firewall_security_groups = {
  block_outbound_private = {
    comment = "Block outbound private IPs."
    rules = [
      { type = "out", action = "DROP", dest = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16", log = "crit" }
    ]
  }
}
```

## Adding a New Cluster

Create a directory named after the cluster as it appears in `console/credentials.conf`:

```bash
mkdir opentofu/clusters/<cluster-name>
```

Then add at least one `.tfvars` group file. Run `iron_bessy → Setup → OpenTofu service account`
for the new cluster before provisioning.
