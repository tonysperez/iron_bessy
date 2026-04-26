#!/usr/bin/env bash
# OpenTofu provisioning: pre-flight setup and plan/apply/destroy orchestration.
#
# action_provision_infrastructure() is the main entry point:
# 1. Reads the pipeline manifest to resolve template names to VMIDs
# 2. Loads Proxmox credentials and prompts for connection details
# 3. Presents a Plan / Apply / Destroy sub-menu
# 4. Runs tofu init, then the selected operation with credentials and template
#    IDs injected via -var flags
#
# Credentials are read from credentials.conf (same clusters as Packer).

# Read the pipeline manifest and return a compact JSON map of image name → VMID.
# Fails early if the manifest is missing or empty so the user gets a clear message
# before tofu ever runs.
_tofu_read_manifest() {
  local manifest="${CONSOLE_DIR}/pipeline/templates.json"
  [[ ! -f "$manifest" || ! -s "$manifest" ]] \
    && die "No pipeline manifest found.\nBuild a VM template first (iron_bessy → Build a VM template)."

  local map
  map="$(jq -c 'with_entries(.value = .value.vm_id)' "$manifest")" \
    || die "Failed to parse pipeline manifest at ${manifest}."

  [[ "$map" == "{}" ]] \
    && die "Pipeline manifest is empty — build a VM template first."

  echo "$map"
}

# Load tofu_username and tofu_token for the active cluster from credentials.conf.
# Overrides PROXMOX_USERNAME and PROXMOX_TOKEN so subsequent Proxmox API calls
# (node selection, etc.) run under the OpenTofu service account.
_tofu_load_credentials() {
  local username token
  username="$(_credentials_get "$PROXMOX_CLUSTER" "tofu_username")"
  token="$(_credentials_get "$PROXMOX_CLUSTER" "tofu_token")"
  [[ -z "$username" || -z "$token" ]] \
    && die "OpenTofu service account has not been provisioned for cluster '${PROXMOX_CLUSTER}', or its secret is unreadable.\nProvision it via the Setup action: iron_bessy → Setup → OpenTofu service account."
  PROXMOX_USERNAME="$username"
  PROXMOX_TOKEN="$token"
  export TF_VAR_proxmox_username="$PROXMOX_USERNAME"
  export TF_VAR_proxmox_token="$PROXMOX_TOKEN"
  success "Loaded OpenTofu credentials for cluster: ${PROXMOX_CLUSTER}"
  echo ""
}

# Write console/pipeline/inventory.<cluster>.json from the `vms` tofu output.
# Wraps each VM with cluster context and an applied_at timestamp so that
# downstream stages (Ansible, etc.) get a complete inventory per cluster.
# Per-cluster files mirror the workspace pattern (terraform.tfstate.d/<cluster>/)
# so applying against one cluster never clobbers another's inventory.
# Idempotent and non-fatal — if outputs aren't available yet, warns and returns.

# Read the current tofu vms output for the active workspace.
# Returns compact JSON (may be "{}"). If `tofu output` fails — which happens
# after a full destroy when the output expression evaluates against an empty
# resource set — falls back to inspecting the state file directly: zero
# resources in state means the workspace was fully destroyed, so return "{}".
# Exits non-zero only when the state cannot be determined at all.
_tofu_current_vms() {
  local out rc=0
  out="$(cd "$TOFU_DIR" && tofu output -json vms 2>/dev/null)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "${out:-"{}"}"
    return 0
  fi

  # tofu output failed — inspect the state file as a fallback.
  local workspace="${PROXMOX_CLUSTER}-${TOFU_GROUP}"
  local state_file="${TOFU_DIR}/terraform.tfstate.d/${workspace}/terraform.tfstate"
  if [[ -f "$state_file" ]]; then
    local count
    count="$(jq '.resources | length' "$state_file" 2>/dev/null)"
    if [[ "${count:-1}" -eq 0 ]]; then
      echo "{}"
      return 0
    fi
  fi

  return 1
}

# Merge the post-operation tofu state into the cluster inventory.
# $1 = pre_scope_json: the vms output captured BEFORE the operation (identifies
#      which keys this config managed so only they are eligible for removal).
#
# Merge logic: (existing inventory) minus (pre-scope keys) plus (new state with metadata).
# Net effect:
#   - Destroyed VMs (in pre-scope, absent from new state) are removed.
#   - Surviving/updated VMs are refreshed with the latest attributes.
#   - VMs from other groups (not in pre-scope) are never touched.
_tofu_write_inventory() {
  local pre_scope_json="${1:-"{}"}"
  local inventory_file="${CONSOLE_DIR}/pipeline/inventory.${PROXMOX_CLUSTER}.json"

  local vms_json rc=0
  vms_json="$(_tofu_current_vms)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Could not read tofu outputs — inventory not updated."
    return 0
  fi

  local existing="{}"
  [[ -f "$inventory_file" ]] && existing="$(< "$inventory_file")"
  [[ -z "$existing" ]] && existing="{}"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq --arg cluster "$PROXMOX_CLUSTER" --arg ts "$timestamp" \
     --argjson pre  "$pre_scope_json" \
     --argjson post "$vms_json" \
     '
    # Drop keys this config owned before (destroyed or replaced below)
    with_entries(select(.key as $k | $pre | has($k) | not))
    # Merge in the surviving/new VMs with cluster metadata
    + ($post | with_entries(.value += {cluster: $cluster, applied_at: $ts}))
  ' <<< "$existing" > "$inventory_file" \
    || { warn "Failed to write inventory."; return 0; }

  success "Inventory written: ${inventory_file}"
}

# Prompt for a cluster-scoped default value. Uses the sentinel "None" in
# console.cache to remember explicit skips, so the user isn't reprompted every run
# for defaults they don't want. Status messages go to stderr; the resolved
# value (or empty for skip) goes to stdout.
_tofu_prompt_default() {
  local key="$1" label="$2"
  local scoped_key="${PROXMOX_CLUSTER}_${key}"
  local saved response
  saved="$(config_get "$scoped_key")"

  if [[ -n "$saved" ]]; then
    [[ "$saved" == "None" ]] && { echo ""; return; }
    info "${label}: ${saved} (cached)" >&2
    echo "$saved"
    return
  fi

  response="$(prompt "${label} (leave blank for none)")"
  if [[ -z "$response" ]]; then
    config_set "$scoped_key" "None"
  else
    config_set "$scoped_key" "$response"
  fi
  echo "$response"
}

# Prompt for cluster-scoped network defaults and append them to _TOFU_VAR_ARGS.
# These fall back when a VM doesn't specify the corresponding field, letting
# infra.auto.tfvars stay compact when most VMs share the same network layout.
_tofu_prompt_network_defaults() {
  header "Network Defaults"
  info "Used when a VM doesn't specify the field. Cached per cluster."
  echo ""

  local vlan gateway dns_servers dns_domain
  vlan="$(_tofu_prompt_default       "VM_DEFAULT_VLAN"        "Default VLAN (1-4094)")"
  gateway="$(_tofu_prompt_default    "VM_DEFAULT_GATEWAY"     "Default IPv4 gateway")"
  dns_servers="$(_tofu_prompt_default "VM_DEFAULT_DNS_SERVERS" "Default DNS servers (comma-separated)")"
  dns_domain="$(_tofu_prompt_default  "VM_DEFAULT_DNS_DOMAIN"  "Default DNS search domain")"

  [[ -n "$vlan" ]]       && _TOFU_VAR_ARGS+=(-var "vm_default_vlan=${vlan}")
  [[ -n "$gateway" ]]    && _TOFU_VAR_ARGS+=(-var "vm_default_gateway=${gateway}")
  [[ -n "$dns_domain" ]] && _TOFU_VAR_ARGS+=(-var "vm_default_dns_domain=${dns_domain}")

  if [[ -n "$dns_servers" ]]; then
    local dns_json
    dns_json="$(jq -c -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))' <<< "$dns_servers")"
    _TOFU_VAR_ARGS+=(-var "vm_default_dns_servers=${dns_json}")
  fi
  echo ""
}

# Run tofu init. Idempotent — only fetches providers if not already present.
_tofu_init() {
  header "Initializing"
  info "Running tofu init..."
  (cd "$TOFU_DIR" && tofu init) \
    || die "tofu init failed — check provider registry access."
  success "Providers ready."
  echo ""
}

# Verify that provider binaries are installed before attempting any operation.
# Guards against cases where .terraform/providers/ is missing or empty —
# e.g. a fresh clone where init was never run, or a corrupted install — so the
# failure is a clear actionable message rather than a cryptic provider-not-found
# error from deep inside a tofu command.
_tofu_check_providers() {
  local providers_dir="${TOFU_DIR}/.terraform/providers"
  if [[ ! -d "$providers_dir" ]] || [[ -z "$(ls -A "$providers_dir" 2>/dev/null)" ]]; then
    die "OpenTofu providers are not installed.\nRun: cd opentofu && tofu init"
  fi
}

# Extract the list of groups declared as dependencies in a tfvars file.
# Reads a line of the form:  group_deps = ["groupA", "groupB"]
# Prints one group name per line; prints nothing if group_deps is absent.
_tofu_read_deps() {
  local tfvars_file="$1"
  [[ ! -f "$tfvars_file" ]] && return 0
  local line
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*group_deps[[:space:]]*=[[:space:]]*\[([^\]]*)\] ]] || continue
    echo "${BASH_REMATCH[1]}" | grep -oP '"[^"]+"' | tr -d '"'
  done < "$tfvars_file"
}

# Check that every group declared in this group's tfvars (group_deps = [...]) both
# exists as a group file AND has applied state in its workspace. Existence is
# checked first so a misspelled or deleted group name is always a hard block
# regardless of any leftover state on disk. Returns 0 if all deps are satisfied
# or none are declared. Exits non-zero and prints a diagnostic for each failure.
_tofu_check_dependencies() {
  local tfvars_file="${TOFU_DIR}/clusters/${PROXMOX_CLUSTER}/${TOFU_GROUP}.tfvars"
  mapfile -t deps < <(_tofu_read_deps "$tfvars_file")
  [[ ${#deps[@]} -eq 0 ]] && return 0

  local dep failed=0
  for dep in "${deps[@]}"; do
    local dep_tfvars="${TOFU_DIR}/clusters/${PROXMOX_CLUSTER}/${dep}.tfvars"
    if [[ ! -f "$dep_tfvars" ]]; then
      error "  Unknown dependency: ${dep}  (no group file at clusters/${PROXMOX_CLUSTER}/${dep}.tfvars)"
      failed=1
      continue
    fi
    local state_file="${TOFU_DIR}/terraform.tfstate.d/${PROXMOX_CLUSTER}-${dep}/terraform.tfstate"
    local ok=0
    if [[ -f "$state_file" ]]; then
      local count
      count="$(jq '.resources | length' "$state_file" 2>/dev/null || echo 0)"
      [[ "${count:-0}" -gt 0 ]] && ok=1
    fi
    if [[ $ok -eq 0 ]]; then
      error "  Unmet dependency: ${dep}  (workspace ${PROXMOX_CLUSTER}-${dep} has no applied state)"
      failed=1
    fi
  done

  return $failed
}

# Check whether any other group in this cluster declares TOFU_GROUP as a
# dependency (via # deps: ...) and still has applied state. Returns 0 if it
# is safe to destroy; exits non-zero and prints a diagnostic for each blocker.
_tofu_check_dependents() {
  local cluster_dir="${TOFU_DIR}/clusters/${PROXMOX_CLUSTER}"
  local blocking=()

  while IFS= read -r tfvars_file; do
    local dependent
    dependent="$(basename "$tfvars_file" .tfvars)"
    [[ "$dependent" == "$TOFU_GROUP" ]] && continue

    local dep found=0
    while IFS= read -r dep; do
      [[ "$dep" == "$TOFU_GROUP" ]] && { found=1; break; }
    done < <(_tofu_read_deps "$tfvars_file")

    if [[ $found -eq 1 ]]; then
      local state_file="${TOFU_DIR}/terraform.tfstate.d/${PROXMOX_CLUSTER}-${dependent}/terraform.tfstate"
      if [[ -f "$state_file" ]]; then
        local count
        count="$(jq '.resources | length' "$state_file" 2>/dev/null || echo 0)"
        [[ "${count:-0}" -gt 0 ]] && blocking+=("$dependent")
      fi
    fi
  done < <(find "$cluster_dir" -maxdepth 1 -name "*.tfvars" 2>/dev/null | sort)

  [[ ${#blocking[@]} -eq 0 ]] && return 0

  for dependent in "${blocking[@]}"; do
    error "  Group '${dependent}' depends on '${TOFU_GROUP}' and has applied state"
  done
  return 1
}

# Discover and select a VM group for the active cluster.
# Groups are all *.tfvars files under opentofu/clusters/<cluster>/.
# Auto-selects when only one group exists. When multiple groups exist the menu is
# always shown so newly added groups are never silently skipped; the last selection
# is cached and shown as the current choice to speed up repeated runs.
# Sets TOFU_GROUP.
_tofu_select_group() {
  local cluster_dir="${TOFU_DIR}/clusters/${PROXMOX_CLUSTER}"
  [[ ! -d "$cluster_dir" ]] \
    && die "No cluster directory at opentofu/clusters/${PROXMOX_CLUSTER}/.\nCreate it and add at least one group tfvars file (e.g. default.tfvars)."

  mapfile -t groups < <(
    find "$cluster_dir" -maxdepth 1 -name "*.tfvars" \
      | sort | while read -r f; do basename "$f" .tfvars; done
  )
  [[ ${#groups[@]} -eq 0 ]] \
    && die "No group tfvars found in opentofu/clusters/${PROXMOX_CLUSTER}/.\n  Create one (e.g. opentofu/clusters/${PROXMOX_CLUSTER}/default.tfvars).\n"

  # Single group: auto-select silently, no Back needed.
  if [[ ${#groups[@]} -eq 1 ]]; then
    _TOFU_MULTIPLE_GROUPS=0
    TOFU_GROUP="${groups[0]}"
    success "Single group found, using: ${TOFU_GROUP}"
    config_set "TOFU_GROUP_${PROXMOX_CLUSTER}" "$TOFU_GROUP"
    echo ""
    return 0
  fi

  # Multiple groups: always prompt; Back returns to the main menu.
  _TOFU_MULTIPLE_GROUPS=1
  local saved
  saved="$(config_get "TOFU_GROUP_${PROXMOX_CLUSTER}")"
  [[ -n "$saved" ]] && info "Current group: ${saved}"

  PS3=$'\n  Select group: '
  local selected
  select selected in "${groups[@]}" "Back"; do
    [[ -n "$selected" ]] && break
    warn "Invalid selection."
  done
  [[ "$selected" == "Back" ]] && return 1

  TOFU_GROUP="$selected"
  config_set "TOFU_GROUP_${PROXMOX_CLUSTER}" "$TOFU_GROUP"
  success "Selected group: ${TOFU_GROUP}"
  echo ""
  return 0
}

# Select (or create) a workspace named <cluster>-<group> so state is isolated
# per (cluster, group) pair. Destroying one group never touches another's state.
_tofu_select_workspace() {
  local workspace="${PROXMOX_CLUSTER}-${TOFU_GROUP}"
  local existing
  existing="$(cd "$TOFU_DIR" && tofu workspace list 2>/dev/null | tr -d '* ' | grep -Fx "$workspace" || true)"

  if [[ -z "$existing" ]]; then
    info "Creating new workspace: ${workspace}"
    (cd "$TOFU_DIR" && tofu workspace new "$workspace" >/dev/null) \
      || die "tofu workspace new '${workspace}' failed."
  else
    (cd "$TOFU_DIR" && tofu workspace select "$workspace" >/dev/null) \
      || die "tofu workspace select '${workspace}' failed."
  fi
  success "Workspace: ${workspace}"
  echo ""
}

# Show a plan. Writes to a temp file so apply can use the exact same plan.
# Sets _TOFU_PLAN_FILE on success.
_tofu_plan_to_file() {
  _TOFU_PLAN_FILE="$(mktemp /tmp/tofu-plan-XXXXXX)"
  header "Planning"
  info "Running tofu plan..."
  echo ""
  (cd "$TOFU_DIR" && tofu plan -out="$_TOFU_PLAN_FILE" "${_TOFU_VAR_ARGS[@]}") \
    || { rm -f "$_TOFU_PLAN_FILE"; die "tofu plan failed — fix errors above."; }
}

_tofu_plan() {
  header "Planning"
  info "Running tofu plan..."
  echo ""
  (cd "$TOFU_DIR" && tofu plan "${_TOFU_VAR_ARGS[@]}")
}

_tofu_apply() {
  _tofu_check_dependencies \
    || die "Apply blocked — apply the required groups first."

  local pre_scope
  pre_scope="$(_tofu_current_vms)" || pre_scope="{}"

  _tofu_plan_to_file

  echo ""
  local confirm
  confirm="$(prompt "Apply the plan above? [y/N]")"
  if [[ "${confirm,,}" != "y" ]]; then
    rm -f "$_TOFU_PLAN_FILE"
    echo ""; info "Aborted."; echo ""; return 0
  fi

  header "Applying"
  info "Running tofu apply..."
  echo ""
  local apply_rc=0
  (cd "$TOFU_DIR" && tofu apply "$_TOFU_PLAN_FILE") || apply_rc=$?
  rm -f "$_TOFU_PLAN_FILE"
  echo ""
  _tofu_write_inventory "$pre_scope"
  [[ $apply_rc -ne 0 ]] && die "tofu apply failed."
  success "Infrastructure applied."
  echo ""
}

_tofu_destroy() {
  _tofu_check_dependents \
    || die "Destroy blocked — destroy dependent groups first."

  local pre_scope
  pre_scope="$(_tofu_current_vms)" || pre_scope="{}"

  echo ""
  warn "This will DESTROY all infrastructure managed by this configuration."
  warn "This action cannot be undone."
  echo ""
  local confirm
  confirm="$(prompt "Type 'destroy' to confirm")"
  [[ "$confirm" != "destroy" ]] && { echo ""; info "Aborted."; echo ""; return 0; }

  local plan_file
  plan_file="$(mktemp /tmp/tofu-plan-XXXXXX)"

  header "Planning Destroy"
  info "Running tofu plan -destroy..."
  echo ""
  (cd "$TOFU_DIR" && tofu plan -destroy -out="$plan_file" "${_TOFU_VAR_ARGS[@]}") \
    || { rm -f "$plan_file"; die "tofu plan -destroy failed."; }

  echo ""
  local final_confirm
  final_confirm="$(prompt "Proceed with destroy? [y/N]")"
  if [[ "${final_confirm,,}" != "y" ]]; then
    rm -f "$plan_file"
    echo ""; info "Aborted."; echo ""; return 0
  fi

  header "Destroying"
  info "Running tofu apply (destroy)..."
  echo ""
  local destroy_rc=0
  (cd "$TOFU_DIR" && tofu apply "$plan_file") || destroy_rc=$?
  rm -f "$plan_file"
  echo ""
  _tofu_write_inventory "$pre_scope"
  [[ $destroy_rc -ne 0 ]] && die "tofu apply (destroy) failed."
  success "Infrastructure destroyed."
  echo ""
}

action_provision_infrastructure() {
  header "Provision Infrastructure"

  local template_vm_ids
  template_vm_ids="$(_tofu_read_manifest)"

  # Cluster-level setup runs once regardless of how many groups are visited.
  proxmox_load_credentials   # cluster selection + scopes console.cache
  _tofu_load_credentials     # override PROXMOX_USERNAME/TOKEN with tofu service account
  proxmox_prompt_url
  proxmox_select_node
  proxmox_select_vm_storage  "$PROXMOX_NODE"
  proxmox_select_bridge      "$PROXMOX_NODE" "tofu"
  proxmox_select_pool "TOFU_VM_POOL"

  local -a _BASE_VAR_ARGS=(
    -var "proxmox_url=${PROXMOX_URL}"
    -var "proxmox_node=${PROXMOX_NODE}"
    -var "proxmox_vm_storage_pool=${PROXMOX_VM_STORAGE}"
    -var "vm_network_bridge=${VM_NETWORK_BRIDGE}"
    -var "template_vm_ids=${template_vm_ids}"
  )
  [[ -n "$PROXMOX_VM_POOL" ]] && _BASE_VAR_ARGS+=(-var "vm_pool=${PROXMOX_VM_POOL}")

  _tofu_init
  _tofu_check_providers

  # Outer loop: re-enters group selection each time the operations menu Back is hit.
  while true; do
    _tofu_select_group || return 0   # Back from group menu → main menu

    # Re-build var args for the selected group.
    _TOFU_VAR_ARGS=("${_BASE_VAR_ARGS[@]}")
    _tofu_prompt_network_defaults

    local cluster_dir="${TOFU_DIR}/clusters/${PROXMOX_CLUSTER}"
    local group_tfvars="${cluster_dir}/${TOFU_GROUP}.tfvars"
    if [[ -f "$group_tfvars" ]]; then
      _TOFU_VAR_ARGS+=(-var-file="$group_tfvars")
    else
      warn "No group tfvars at clusters/${PROXMOX_CLUSTER}/${TOFU_GROUP}.tfvars — only shared values will apply."
    fi

    info "Configuration:"
    echo -e "      Cluster:   ${BOLD}${PROXMOX_CLUSTER}${RESET}"
    echo -e "      Group:     ${BOLD}${TOFU_GROUP}${RESET}"
    echo -e "      URL:       ${BOLD}${PROXMOX_URL}${RESET}"
    echo -e "      Node:      ${BOLD}${PROXMOX_NODE}${RESET}"
    echo -e "      Storage:   ${BOLD}${PROXMOX_VM_STORAGE}${RESET}"
    echo -e "      Bridge:    ${BOLD}${VM_NETWORK_BRIDGE}${RESET}"
    echo -e "      Templates: ${BOLD}${template_vm_ids}${RESET}"
    echo ""

    _tofu_select_workspace

    # Inner loop: operations for the selected group.
    while true; do
      local -a operations=("Plan")

      if _tofu_check_dependencies 2>/dev/null; then
        operations+=("Apply")
      else
        _tofu_check_dependencies
        warn "Apply blocked — apply the required groups first."
        echo ""
      fi

      if _tofu_check_dependents 2>/dev/null; then
        operations+=("Destroy")
      else
        _tofu_check_dependents
        warn "Destroy blocked — destroy dependent groups first."
        echo ""
      fi

      operations+=("Back")

      PS3=$'\n  Operation: '
      local operation
      select operation in "${operations[@]}"; do
        [[ -n "$operation" ]] && break
        warn "Invalid selection, try again."
      done
      echo ""

      if [[ "$operation" == "Back" ]]; then
        # Single group: no selection screen to return to, go to main menu.
        [[ $_TOFU_MULTIPLE_GROUPS -eq 0 ]] && return 0
        break   # Multiple groups: break inner loop → re-show group selection.
      fi

      case "$operation" in
        "Plan")    (_tofu_plan) || true ;;
        "Apply")   (_tofu_apply) || true ;;
        "Destroy") (_tofu_destroy) || true ;;
      esac
    done
  done
}
