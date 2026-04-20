
# iron_bessy

IaC pipeline for building, provisioning, and configuring virtual machines on Proxmox. Orchestrated through an interactive console that guides each stage from raw ISO to a fully configured, policy-checked server.

## Prerequisites

**Proxmox Infrastructure:**
- At least 1 Proxmox node, either stand-alone or in a cluster
- An API token with Packer builder permissions (user: `packer@pve`)
- An ISO storage pool with Ubuntu 24.04 LTS Server ISO
- A VM storage pool with sufficient capacity (≥30GB per template)

**Installed Locally:**
- bash (≥ 4.0)
- curl
- jq
- packer (HashiCorp Packer)
- genisoimage, xorriso, or mkisofs (for ISO generation)

**Security Note:** This project uses `insecure_skip_tls_verify = true` for homelab environments. **Do not use in production** without proper certificate validation.

```mermaid
flowchart LR
    ISO([Boot ISO]) --> P

    subgraph P ["Packer — Templates"]
        direction TB
        P1[Build VM] --> P2[Cloud-init<br/>provisioning]
        P2 --> P3[Template]
    end

    P3 --> T

    subgraph T ["OpenTofu — Infrastructure"]
        direction TB
        T1[Clone template] --> T2[Provisioned VM]
    end

    T2 --> A

    subgraph A ["Ansible — Configuration"]
        direction TB
        A1[Apply roles] --> A2[Configured VM]
    end

    CON[iron_bessy<br/>console] --->|orchestrates| P
    CON --->|orchestrates| T
    CON --->|orchestrates| A
```

## Concepts

**Each stage is independent but feeds the next.** Packer produces a Proxmox VM template; OpenTofu clones it into running infrastructure; Ansible configures what's running. The console drives all three from a single menu without requiring the operator to manage credentials or remember arguments between runs.

**Configuration is cached, credentials are not.** The console caches node selections, storage pools, network bridges, and VLANs in a local `.config` file scoped by cluster. Proxmox API credentials live only in `.credentials` and are injected as environment variables, they never touch the command line or get written into build artifacts.

**The pipeline manifest is the handoff between stages.** After a successful Packer build, `console/pipeline/templates.json` is updated with the template's VMID and name. OpenTofu reads this file to know what to clone, so there is no hard-coded ID to keep in sync.

## Repository Layout

```
iron_bessy/
├── packer/       # VM template build configs and cloud-init
├── console/      # Interactive pipeline console (iron_bessy.sh)
│   └── pipeline/ # Build artifact manifests consumed by downstream stages
├── tofu/         # OpenTofu infrastructure configs         (planned)
└── ansible/      # Ansible roles and playbooks             (planned)
```

See [packer/README.md](packer/README.md) and [console/README.md](console/README.md) for documentation of the current implementation.

## Quick Start

1. **Create credentials file:**
   ```bash
   cp console/.credentials.example console/.credentials
   # Edit with your Proxmox API token credentials
   ```

2. **Create image secrets file:**
   ```bash
   cp packer/ubuntu-server-2404-core/secrets.pkrvars.hcl.example \
      packer/ubuntu-server-2404-core/secrets.pkrvars.hcl
   # Edit with your template build username and password
   ```

3. **Verify prerequisites:** Ensure the Ubuntu ISO exists in your Proxmox ISO storage pool (path defined in `packer/ubuntu-server-2404-core.pkr.hcl`).

4. **Run the console:**
   ```bash
   ./console/iron_bessy.sh
   ```
   Follow the interactive prompts. On first run, all parameters will be prompted. Subsequent runs restore cached values.

## Roadmap

### Step 1 — Packer + Console (Ubuntu) `complete`

Interactive console wrapping Packer to build Ubuntu 24.04 Server templates on Proxmox. Handles dynamic resource discovery, cluster-scoped config caching, VMID conflict resolution, and pipeline manifest output.

### Step 2 — OpenTofu (Ubuntu) `in progress`

Provision VMs by cloning the Packer-built Ubuntu template. VMID sourced from `pipeline/templates.json`. Console extended with a new pipeline stage to drive the apply.

### Step 3 — Ansible (Ubuntu) `todo`

Post-provision configuration via Ansible roles. Console stage to trigger playbook runs against newly provisioned hosts.

### Step 4 — Windows Server 2025 `todo`

Extend the full pipeline (Packer → OpenTofu → Ansible) for Windows Server 2025. Separate image config, WinRM communicator, and Windows-specific Ansible roles.

### Step 5 — Security as Code `todo`

- **Packer:** Integrate Trivy/Grype image scanning. Fail the build on findings above threshold.
- **OpenTofu:** Add tfsec/Checkov to pre-commit hooks. Block applies with policy violations.
- **OPA:** One custom Rego policy enforcing environment-specific constraints across the pipeline.
- **Ansible:** CIS hardening via [ansible-lockdown](https://github.com/ansible-lockdown).

### Step ? - Use VSCode Dev Container

For easy portability, use a local docker container as the runtime. Handles all dependendies cleanly, especially for Windows machines.

## Security & Production Deployment

### Homelab Configuration (Current)

This project is currently designed for home-lab environments.

### Production Hardening

Before deploying to production, address:

1. **TLS/Certificate Validation**
   - Set `insecure_skip_tls_verify = false` in `packer/ubuntu-server-2404-core.pkr.hcl` line 54
   - Use `curl -H` without `-k` flag in shell scripts
   - Install proper CA certificates in your environment

2. **Credentials Management**
   - Use secrets manager
   - Rotate API tokens regularly

3. **Template Security**
   - Remove `NOPASSWD:ALL` sudo grant in `packer/ubuntu-server-2404-core/cloudinit/user-data.pkrtpl` line 43
   - Implement key-based SSH authentication instead of password auth

4. **Access Control**
   - Create dedicated Packer API token with minimal required permissions
   - Use separate tokens per environment (dev/staging/prod)
   - Audit API token usage regularly

## License
Licensed under GPLv3, see LICENSE.