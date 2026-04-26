#!/usr/bin/env bash
# Proxmox API interaction: credentials, resource queries, and interactive selectors.
# All API calls use curl with TLS verification disabled (intentional for homelab).
# Functions export variables (e.g., PROXMOX_URL) and cache values to console.cache.

# Parse cluster section names from the credentials.conf INI file.
# Sections prefixed with sys: are reserved for console-internal configuration
# (e.g. [sys:packer]) and are excluded from the cluster list.
_credentials_list_clusters() {
  grep '^\[' "${CONSOLE_DIR}/credentials.conf" 2>/dev/null \
    | grep -v '^\[sys:' \
    | tr -d '[]'
}

# Read a key's value from a named section of the credentials.conf INI file.
# Inline comments (` #...` after whitespace) are stripped from the value.
#
# This parses a simple INI format:
#   [section-name]
#   key = value        # unquoted
#   key = "value"      # HCL-style quoted strings are also accepted
#   key = value  # inline comment
#
# awk logic:
#   1. Track which section we're in (/^\[/ detects section headers)
#   2. When in the target section, find the key= line
#   3. Extract value after = and trim leading/trailing whitespace
#   4. Remove inline comments (everything after whitespace + #)
#   5. Strip surrounding double quotes (tolerates HCL-style values)
#   6. Exit after finding the first match
_credentials_get() {
  local cluster="$1" key="$2"
  awk -v sec="[${cluster}]" -v key="$key" '
    /^\[/ { in_sec = ($0 == sec) }
    in_sec && /=/ {
      k = $0; sub(/[[:space:]]*=.*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) {
        v = $0
        sub(/[^=]*=[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        print v; exit
      }
    }
  ' "${CONSOLE_DIR}/credentials.conf" 2>/dev/null
}

# Load credentials for a cluster into env vars for both curl and Packer.
# Also sets PROXMOX_CLUSTER so all subsequent config_get/config_set calls are scoped.
_credentials_load() {
  local cluster="$1"
  PROXMOX_CLUSTER="$cluster"
  PROXMOX_USERNAME="$(_credentials_get "$cluster" "packer_username")"
  PROXMOX_TOKEN="$(_credentials_get "$cluster" "packer_token")"
  [[ -z "$PROXMOX_USERNAME" || -z "$PROXMOX_TOKEN" ]] \
    && die "Packer service account has not been provisioned for cluster '${cluster}', or its secret is unreadable.\nProvision it via the Setup action: iron_bessy → Setup → Packer service account."
  export PKR_VAR_proxmox_username="$PROXMOX_USERNAME"
  export PKR_VAR_proxmox_token="$PROXMOX_TOKEN"
}

# Select a cluster from credentials.conf and load its credentials.
proxmox_load_credentials() {
  local creds_file="${CONSOLE_DIR}/credentials.conf"
  [[ ! -f "$creds_file" ]] \
    && die "No credentials.conf file found.\nService accounts have not been provisioned yet — run iron_bessy → Setup to bootstrap a cluster."

  mapfile -t clusters < <(_credentials_list_clusters)
  [[ ${#clusters[@]} -eq 0 ]] \
    && die "No clusters configured in credentials.conf.\nService accounts have not been provisioned yet — run iron_bessy → Setup to bootstrap a cluster."

  if [[ ${#clusters[@]} -eq 1 ]]; then
    _credentials_load "${clusters[0]}"
    success "Using credentials for cluster: ${clusters[0]}"
    echo ""
    config_set PROXMOX_CLUSTER "${clusters[0]}"
    return
  fi

  local saved
  saved="$(config_get PROXMOX_CLUSTER)"

  info "Available clusters${saved:+ (last used: ${saved})}:"
  local selected
  PS3=$'\n  Select cluster: '
  select selected in "${clusters[@]}"; do
    [[ -n "$selected" ]] && break
    warn "Invalid selection, try again."
  done
  _credentials_load "$selected"
  success "Using credentials for cluster: ${selected}"
  echo ""
  config_set PROXMOX_CLUSTER "$selected"
}

# Prompt for Proxmox URL, saving/restoring the last used value.
proxmox_prompt_url() {
  local saved
  saved="$(config_get PROXMOX_URL)"

  if [[ -n "$saved" && "${NO_CACHE:-0}" != "1" ]]; then
    PROXMOX_URL="$saved"
    success "Using saved Proxmox URL: ${PROXMOX_URL}"
    echo ""
    return
  fi

  PROXMOX_URL="$(prompt "Proxmox URL (e.g. https://proxmox.example.com:8006)" "$saved")"
  [[ -z "$PROXMOX_URL" ]] && die "Proxmox URL is required."
  echo ""
  config_set PROXMOX_URL "$PROXMOX_URL"
}

# Query the Proxmox API and return a newline-separated list of node names.
proxmox_get_nodes() {
  local response
  response=$(curl -sf -k \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "${PROXMOX_URL}/api2/json/nodes") \
    || die "Failed to reach Proxmox API at ${PROXMOX_URL}. Check the URL and credentials."

  local nodes
  nodes=$(echo "$response" | jq -r '.data[].node' 2>/dev/null) \
    || die "Failed to parse node list from API response."

  [[ -z "$nodes" ]] && die "Proxmox returned no nodes. Check API token permissions."
  echo "$nodes"
}

# Query the node for storage pools supporting a given content type (e.g. images, iso).
proxmox_get_storage() {
  local node="$1" content_type="$2"
  local response
  response=$(curl -sf -k \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "${PROXMOX_URL}/api2/json/nodes/${node}/storage?enabled=1") \
    || die "Failed to query storage on node ${node}."

  local pools
  pools=$(echo "$response" | jq -r --arg ct "$content_type" '
    .data[]
    | select(.active == 1 and (.content // "" | split(",") | any(. == $ct)))
    | .storage
  ' 2>/dev/null) \
    || die "Failed to parse storage list from API response."

  [[ -z "$pools" ]] && die "No ${content_type}-capable storage found on ${node}."
  echo "$pools"
}

# Generic storage selector. Sets the bash variable named $var and saves to console.cache.
# Usage: proxmox_select_storage <node> <content-type> <var> <label>
proxmox_select_storage() {
  local node="$1" content_type="$2" var="$3" label="$4"
  info "Querying ${label} pools on ${node}..."
  mapfile -t pools < <(proxmox_get_storage "$node" "$content_type")

  local saved
  saved="$(config_get "$var")"

  if [[ -n "$saved" ]]; then
    local match
    for p in "${pools[@]}"; do [[ "$p" == "$saved" ]] && match=1 && break; done
    if [[ -n "${match:-}" ]]; then
      if [[ "${NO_CACHE:-0}" != "1" ]]; then
        printf -v "$var" '%s' "$saved"
        success "Using saved ${label}: ${saved}"
        echo ""
        return
      fi
    else
      warn "Saved ${label} '${saved}' not found on ${node} — please select again."
      echo ""
      saved=""
    fi
  fi

  if [[ ${#pools[@]} -eq 1 ]]; then
    printf -v "$var" '%s' "${pools[0]}"
    success "Single ${label} found, using: ${pools[0]}"
    echo ""
    config_set "$var" "${pools[0]}"
    return
  fi

  local selected
  PS3=$'\n  Select '"${label}"': '
  [[ -n "$saved" ]] && info "Last used: ${saved}"
  select selected in "${pools[@]}"; do
    [[ -n "$selected" ]] && break
    warn "Invalid selection, try again."
  done
  printf -v "$var" '%s' "$selected"
  success "Selected ${label}: ${selected}"
  echo ""
  config_set "$var" "$selected"
}

proxmox_select_vm_storage()  { proxmox_select_storage "$1" "images" "PROXMOX_VM_STORAGE"  "VM storage";  }
proxmox_select_iso_storage() { proxmox_select_storage "$1" "iso"    "PROXMOX_ISO_STORAGE" "ISO storage"; }

# Select a network bridge on a node for a specific image. Cached per image in console.cache.
proxmox_select_bridge() {
  local node="$1" image="$2"
  local config_key="VM_NETWORK_BRIDGE_${image}"

  local saved
  saved="$(config_get "$config_key")"

  info "Querying network bridges on ${node}..."
  local response
  response=$(curl -sf -k \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "${PROXMOX_URL}/api2/json/nodes/${node}/network?type=bridge") \
    || die "Failed to query network bridges on ${node}."

  mapfile -t bridges < <(echo "$response" | jq -r '.data[].iface' 2>/dev/null | sort)
  [[ ${#bridges[@]} -eq 0 ]] && die "No bridges found on ${node}."

  if [[ -n "$saved" ]]; then
    local match
    for b in "${bridges[@]}"; do [[ "$b" == "$saved" ]] && match=1 && break; done
    if [[ -n "${match:-}" ]]; then
      if [[ "${NO_CACHE:-0}" != "1" ]]; then
        VM_NETWORK_BRIDGE="$saved"
        success "Using saved bridge for ${image}: ${VM_NETWORK_BRIDGE}"
        echo ""
        return
      fi
    else
      warn "Saved bridge '${saved}' not found on ${node} — please select again."
      echo ""
      saved=""
    fi
  fi

  if [[ ${#bridges[@]} -eq 1 ]]; then
    VM_NETWORK_BRIDGE="${bridges[0]}"
    success "Single bridge found, using: ${VM_NETWORK_BRIDGE}"
    echo ""
    config_set "$config_key" "$VM_NETWORK_BRIDGE"
    return
  fi

  local selected
  PS3=$'\n  Select bridge for '"${image}"': '
  [[ -n "$saved" ]] && info "Last used: ${saved}"
  select selected in "${bridges[@]}"; do
    [[ -n "$selected" ]] && break
    warn "Invalid selection, try again."
  done
  VM_NETWORK_BRIDGE="$selected"
  success "Selected bridge: ${VM_NETWORK_BRIDGE}"
  echo ""
  config_set "$config_key" "$VM_NETWORK_BRIDGE"
}

# Select a Proxmox resource pool and set PROXMOX_VM_POOL (empty string = no pool).
# Optional first argument: cache key to use (default: PROXMOX_VM_POOL).
# Using separate cache keys for Packer (PACKER_VM_POOL) and Tofu (TOFU_VM_POOL)
# prevents a "None" selection in one tool from poisoning the other's cached value.
proxmox_select_pool() {
  local cache_key="${1:-PROXMOX_VM_POOL}"
  info "Querying resource pools..."
  local response
  response=$(curl -sf -k \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "${PROXMOX_URL}/api2/json/pools") \
    || die "Failed to query resource pools."

  mapfile -t pools < <(echo "$response" | jq -r '.data[].poolid' 2>/dev/null | sort)

  # Saved value is "None" (sentinel) or a pool name. Absent = never been set.
  local saved
  saved="$(config_get "$cache_key")"

  if [[ -n "$saved" ]]; then
    local match=1
    if [[ "$saved" != "None" ]]; then
      match=
      for p in "${pools[@]}"; do [[ "$p" == "$saved" ]] && match=1 && break; done
    fi
    if [[ -n "$match" ]]; then
      if [[ "${NO_CACHE:-0}" != "1" ]]; then
        [[ "$saved" == "None" ]] && PROXMOX_VM_POOL="" || PROXMOX_VM_POOL="$saved"
        success "Using saved resource pool: ${saved}"
        echo ""
        return
      fi
    else
      warn "Saved pool '${saved}' not found — please select again."
      echo ""
      saved=""
    fi
  fi

  # Build menu: prepend "None" so the user can opt out.
  local options=("None" "${pools[@]}")
  local selected
  PS3=$'\n  Select resource pool: '
  [[ -n "$saved" ]] && info "Last used: ${saved}"
  select selected in "${options[@]}"; do
    [[ -n "$selected" ]] && break
    warn "Invalid selection, try again."
  done

  [[ "$selected" == "None" ]] && PROXMOX_VM_POOL="" || PROXMOX_VM_POOL="$selected"
  success "Using resource pool: ${selected}"
  echo ""
  config_set "$cache_key" "$selected"
}

# Check if a VMID is already in use. If it is:
#   - Same name as expected → require the user to type the VM name to confirm deletion.
#   - Different name        → hard error; do not touch it.
proxmox_check_vmid() {
  local node="$1" vmid="$2" expected_name="$3"

  info "Checking if VMID ${vmid} is already in use..."
  local response
  response=$(curl -sf -k \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "${PROXMOX_URL}/api2/json/cluster/resources?type=vm") \
    || die "Failed to query cluster resources."

  local existing_name existing_node
  existing_name=$(echo "$response" | jq -r --argjson id "$vmid" \
    '.data[] | select(.vmid == $id) | .name' 2>/dev/null | head -1)

  if [[ -z "$existing_name" ]]; then
    success "VMID ${vmid} is available."
    echo ""
    return
  fi

  existing_node=$(echo "$response" | jq -r --argjson id "$vmid" \
    '.data[] | select(.vmid == $id) | .node' 2>/dev/null | head -1)

  if [[ "$existing_name" != "$expected_name" ]]; then
    die "VMID ${vmid} is in use by '${existing_name}' on ${existing_node}.\nExpected '${expected_name}'. Resolve this conflict manually before building."
  fi

  echo ""
  warn "VMID ${vmid} ('${existing_name}') already exists on ${existing_node}."
  warn "It must be deleted before Packer can build. This cannot be undone."
  echo ""
  info "Type the VM name exactly to confirm deletion, or press Enter to abort:"
  echo ""
  local input
  input="$(prompt "VM name")"

  if [[ "$input" != "$existing_name" ]]; then
    echo ""
    info "Name did not match — aborted."
    echo ""
    exit 0
  fi

  echo ""
  info "Deleting VMID ${vmid} (${existing_name}) on ${existing_node}..."
  curl -sf -k -X DELETE \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "${PROXMOX_URL}/api2/json/nodes/${existing_node}/qemu/${vmid}?purge=1&destroy-unreferenced-disks=1" \
    > /dev/null \
    || die "Failed to delete VMID ${vmid}."

  info "Waiting for deletion to complete..."
  local retries=30
  while (( retries-- > 0 )); do
    if ! curl -sf -k \
      -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
      "${PROXMOX_URL}/api2/json/nodes/${existing_node}/qemu/${vmid}/status/current" \
      > /dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  (( retries < 0 )) && die "Timed out waiting for VMID ${vmid} to be deleted."

  success "Deleted '${existing_name}'."
  echo ""
}

# Verify a Proxmox volid (e.g. local:iso/ubuntu.iso) exists on a given node.
proxmox_check_iso() {
  local node="$1" volid="$2"
  local storage="${volid%%:*}"

  info "Verifying ISO on ${node}/${storage}: ${volid}..."
  local response
  response=$(curl -sf -k \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "${PROXMOX_URL}/api2/json/nodes/${node}/storage/${storage}/content?content=iso") \
    || die "Failed to query storage ${storage} on node ${node}."

  if echo "$response" | jq -e --arg v "$volid" '.data[] | select(.volid == $v)' > /dev/null 2>&1; then
    success "ISO found: ${volid}"
    echo ""
  else
    die "ISO not found on ${node}/${storage}: ${volid}\nUpload it to Proxmox before building."
  fi
}

# Prompt the user to select a node and set PROXMOX_NODE.
proxmox_select_node() {
  info "Querying Proxmox nodes at ${PROXMOX_URL}..."
  mapfile -t nodes < <(proxmox_get_nodes)

  local saved
  saved="$(config_get PROXMOX_NODE)"

  if [[ -n "$saved" ]]; then
    local match
    for n in "${nodes[@]}"; do [[ "$n" == "$saved" ]] && match=1 && break; done
    if [[ -n "${match:-}" ]]; then
      if [[ "${NO_CACHE:-0}" != "1" ]]; then
        PROXMOX_NODE="$saved"
        success "Using saved node: ${PROXMOX_NODE}"
        echo ""
        return
      fi
    else
      warn "Saved node '${saved}' not found — please select again."
      echo ""
      saved=""
    fi
  fi

  if [[ ${#nodes[@]} -eq 1 ]]; then
    PROXMOX_NODE="${nodes[0]}"
    success "Single node found, using: ${PROXMOX_NODE}"
    echo ""
    config_set PROXMOX_NODE "$PROXMOX_NODE"
    return
  fi

  PS3=$'\n  Select node: '
  [[ -n "$saved" ]] && info "Last used: ${saved}"
  select PROXMOX_NODE in "${nodes[@]}"; do
    [[ -n "$PROXMOX_NODE" ]] && break
    warn "Invalid selection, try again."
  done
  success "Selected node: ${PROXMOX_NODE}"
  echo ""
  config_set PROXMOX_NODE "$PROXMOX_NODE"
}
