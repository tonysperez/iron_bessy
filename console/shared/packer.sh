#!/usr/bin/env bash
# Packer build orchestration: image discovery, pre-flight validation, and manifest output.
#
# The main action is action_build_template(), which:
# 1. Discovers available image configs in packer/
# 2. Loads Proxmox credentials and prompts for resource selection
# 3. Validates ISO availability and VMID conflicts
# 4. Runs packer init/validate/build
# 5. Updates the build manifest (pipeline/templates.json)

# Load pipeline account credentials from the [sys:packer] section of credentials.conf
# and export them as PKR_VAR_* environment variables. Keeps sensitive values
# off the command line and out of any file visible to packer build output.
_packer_load_image_credentials() {
  local template_username template_password ansible_username ansible_ssh_key breakglass_username breakglass_ssh_key
  template_username="$(_credentials_get "sys:packer" "template_username")"
  template_password="$(_credentials_get "sys:packer" "template_password")"
  ansible_username="$(_credentials_get "sys:packer" "ansible_username")"
  ansible_ssh_key="$(_credentials_get "sys:packer" "ansible_ssh_key")"
  breakglass_username="$(_credentials_get "sys:packer" "breakglass_username")"
  breakglass_ssh_key="$(_credentials_get "sys:packer" "breakglass_ssh_key")"

  [[ -z "$template_username"  ]] && die "template_username not set in [packer] section of credentials.conf."
  [[ -z "$template_password"  ]] && die "template_password not set in [packer] section of credentials.conf."
  [[ -z "$ansible_ssh_key"    ]] && die "ansible_ssh_key not set in [packer] section of credentials.conf."
  [[ -z "$breakglass_ssh_key" ]] && die "breakglass_ssh_key not set in [packer] section of credentials.conf."

  export PKR_VAR_template_username="$template_username"
  export PKR_VAR_template_password="$template_password"
  export PKR_VAR_ansible_username="${ansible_username:-ansible}"
  export PKR_VAR_ansible_ssh_key="$ansible_ssh_key"
  export PKR_VAR_breakglass_username="${breakglass_username:-breakglass}"
  export PKR_VAR_breakglass_ssh_key="$breakglass_ssh_key"

  success "Loaded image credentials from credentials.conf"
  echo ""
}

# Parse a variable value from a .pkrvars.hcl file.
_pkrvars_get() {
  local file="$1" key="$2"
  grep "^${key}[[:space:]]*=" "$file" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' | head -1
}

# Read a variable's value for an image: checks image secrets file, then falls
# back to the default in the image's variable declaration file.
packer_get_variable() {
  local image="$1" varname="$2"
  local val
  val="$(_pkrvars_get "${PACKER_DIR}/global_secrets.pkrvars.hcl" "$varname")"
  [[ -n "$val" ]] && echo "$val" && return
  awk -v name="$varname" '
    $0 ~ "variable[[:space:]]+\"" name "\"" { in_block=1; next }
    in_block && /^[[:space:]]*default[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/"/, "")
      sub(/[[:space:]]+$/, "")
      print; exit
    }
    in_block && /^}/ { exit }
  ' "${PACKER_DIR}/${image}/${image}.pkr.hcl" 2>/dev/null
}

# Prompt for the network VLAN for an image, cached per-image in console.cache.
packer_select_vlan() {
  local image="$1"
  local config_key="VM_NETWORK_VLAN_${image}"
  local saved
  saved="$(config_get "$config_key")"

  if [[ -n "$saved" && "${NO_CACHE:-0}" != "1" ]]; then
    VM_NETWORK_VLAN="$saved"
    success "Using saved VLAN for ${image}: ${VM_NETWORK_VLAN}"
    echo ""
    return
  fi

  local vlan
  while true; do
    vlan="$(prompt "Network VLAN tag for ${image} (1-4094)" "$saved")"
    if [[ "$vlan" =~ ^[0-9]+$ ]] && (( vlan >= 1 && vlan <= 4094 )); then
      break
    fi
    warn "Invalid VLAN — must be a number between 1 and 4094."
    echo ""
  done
  VM_NETWORK_VLAN="$vlan"
  echo ""
  config_set "$config_key" "$VM_NETWORK_VLAN"
}

# Extract the vm_name literal from the source block of a build config.
packer_get_vm_name() {
  local image="$1"
  grep -m1 'vm_name' "${PACKER_DIR}/${image}/${image}.pkr.hcl" 2>/dev/null \
    | sed 's/.*= *"\(.*\)"/\1/'
}

# Write (or update) console/pipeline/templates.json with the built template's identity.
packer_write_pipeline_manifest() {
  local image="$1" vm_name="$2" vmid="$3"
  local manifest_dir="${CONSOLE_DIR}/pipeline"
  local manifest_file="${manifest_dir}/templates.json"

  mkdir -p "$manifest_dir"

  [[ -z "$vmid" ]] && warn "VMID unknown for ${image} — skipping manifest update." && echo "" && return

  local existing="{}"
  [[ -f "$manifest_file" && -s "$manifest_file" ]] && existing="$(cat "$manifest_file")"

  local built_at
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "$existing" | jq \
    --arg image "$image" \
    --arg vm_name "$vm_name" \
    --arg vm_id "$vmid" \
    --arg built_at "$built_at" \
    '.[$image] = {vm_name: $vm_name, vm_id: ($vm_id | tonumber), built_at: $built_at}' \
    > "${manifest_file}.tmp" && mv "${manifest_file}.tmp" "$manifest_file"

  success "Pipeline manifest updated: ${manifest_file}"
  echo ""
}

# Discover build configs: subdirectories that contain a matching <name>.pkr.hcl file.
packer_list_images() {
  find "$PACKER_DIR" -mindepth 1 -maxdepth 1 -type d \
    | while IFS= read -r dir; do
        local image
        image="$(basename "$dir")"
        [[ -f "${dir}/${image}.pkr.hcl" ]] && echo "$image"
      done | sort
}

# Parse the --only glob from a build config file.
# HCL2 format: <build-name>.<type>.<source-name>
# We use a glob for <build-name> to avoid hardcoding it.
packer_only_filter() {
  local image="$1"
  local hcl="${PACKER_DIR}/${image}/${image}.pkr.hcl"

  local type name
  type=$(grep -m1 '^source "' "$hcl" | awk -F'"' '{print $2}')
  name=$(grep -m1 '^source "' "$hcl" | awk -F'"' '{print $4}')

  [[ -z "$type" || -z "$name" ]] && die "Could not parse source block from ${hcl}."
  echo "*.${type}.${name}"
}

action_build_template() {
  header "Build VM Template"

  # ── Select image ────────────────────────────────────────────────────────────
  info "Scanning for available images..."
  mapfile -t images < <(packer_list_images)
  [[ ${#images[@]} -eq 0 ]] && die "No build configs found in ${PACKER_DIR}."

  local image
  echo ""
  PS3=$'\n  Select image: '
  select image in "${images[@]}"; do
    [[ -n "$image" ]] && break
    warn "Invalid selection, try again."
  done
  success "Selected: ${image}"
  echo ""

  # ── Pre-flight setup ────────────────────────────────────────────────────────
  proxmox_load_credentials    # must be first — sets PROXMOX_CLUSTER to scope console.cache
  _packer_load_image_credentials
  packer_select_vlan "$image"
  proxmox_prompt_url
  proxmox_select_node
  proxmox_select_vm_storage  "$PROXMOX_NODE"
  proxmox_select_iso_storage "$PROXMOX_NODE"
  proxmox_select_bridge      "$PROXMOX_NODE" "$image"
  proxmox_select_pool

  # ── Verify ISO exists on selected node ──────────────────────────────────────
  local iso
  iso="$(packer_get_variable "$image" vm_boot_iso)"
  if [[ -n "$iso" ]]; then
    proxmox_check_iso "$PROXMOX_NODE" "$iso"
  else
    warn "Could not determine vm_boot_iso for ${image} — skipping ISO check."
    echo ""
  fi

  # ── Check VMID availability ─────────────────────────────────────────────────
  local vmid vm_name
  vmid="$(packer_get_variable "$image" vm_id)"
  vm_name="$(packer_get_vm_name "$image")"
  if [[ -n "$vmid" && -n "$vm_name" ]]; then
    proxmox_check_vmid "$PROXMOX_NODE" "$vmid" "$vm_name"
  else
    warn "Could not determine VMID or VM name for ${image} — skipping conflict check."
    echo ""
  fi

  # ── Build args ──────────────────────────────────────────────────────────────
  local source
  source="$(packer_only_filter "$image")"
  local packer_args=(
    -var "proxmox_url=${PROXMOX_URL}/api2/json"
    -var "proxmox_node=${PROXMOX_NODE}"
    -var "proxmox_vm_storage_pool=${PROXMOX_VM_STORAGE}"
    -var "proxmox_iso_storage_pool=${PROXMOX_ISO_STORAGE}"
    -var "proxmox_vm_pool=${PROXMOX_VM_POOL}"
    -var "vm_network_vlan=${VM_NETWORK_VLAN}"
    -var "vm_network_bridge=${VM_NETWORK_BRIDGE}"
    --only="${source}"
  )

  # ── Confirm ─────────────────────────────────────────────────────────────────
  info "Build parameters:"
  echo -e "      Image:       ${BOLD}${image}${RESET}"
  echo -e "      VM ID:       ${BOLD}${vmid}${RESET}"
  echo -e "      VM Name:     ${BOLD}${vm_name}${RESET}"
  echo -e "      Cluster:     ${BOLD}${PROXMOX_CLUSTER}${RESET}"
  echo -e "      URL:         ${BOLD}${PROXMOX_URL}${RESET}"
  echo -e "      Node:        ${BOLD}${PROXMOX_NODE}${RESET}"
  echo -e "      VM Storage:  ${BOLD}${PROXMOX_VM_STORAGE}${RESET}"
  echo -e "      ISO Storage: ${BOLD}${PROXMOX_ISO_STORAGE}${RESET}"
  echo -e "      Bridge:      ${BOLD}${VM_NETWORK_BRIDGE}${RESET}"
  echo -e "      VLAN:        ${BOLD}${VM_NETWORK_VLAN}${RESET}"
  echo -e "      Pool:        ${BOLD}${PROXMOX_VM_POOL:-None}${RESET}"
  echo ""
  local confirm
  confirm="$(prompt "Proceed with build? [y/N]")"
  [[ "${confirm,,}" != "y" ]] && { echo ""; info "Aborted."; echo ""; return 0; }

  local image_dir="${PACKER_DIR}/${image}"

  # Ensure global_variables.pkr.hcl is visible from the image directory so
  # packer can be pointed at the image dir as a single self-contained template.
  local global_link="${image_dir}/global_variables.pkr.hcl"
  if [[ ! -e "$global_link" ]]; then
    ln -s "../global_variables.pkr.hcl" "$global_link"
  fi

  # ── Init (idempotent — fetches required plugins) ────────────────────────────
  header "Initializing"
  info "Running packer init..."
  if ! (cd "$image_dir" && packer init .); then
    die "packer init failed — could not fetch required plugins."
  fi
  success "Plugins ready."
  echo ""

  # ── Validate ────────────────────────────────────────────────────────────────
  header "Validating"
  info "Running packer validate..."
  if ! (cd "$image_dir" && packer validate "${packer_args[@]}" .); then
    die "Validation failed — fix the errors above before building."
  fi
  success "Validation passed."
  echo ""

  # ── Build ───────────────────────────────────────────────────────────────────
  header "Building"
  info "Starting build: ${image} → node ${PROXMOX_NODE}"
  echo ""

  local exit_code=0
  (cd "$image_dir" && packer build "${packer_args[@]}" .) || exit_code=$?

  echo ""
  if [[ $exit_code -eq 0 ]]; then
    success "Build complete: ${image}"
    echo ""
    packer_write_pipeline_manifest "$image" "$vm_name" "$vmid"
  else
    error "Build exited with code ${exit_code}."
    echo ""
    return "$exit_code"
  fi
}
