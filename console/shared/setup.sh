#!/usr/bin/env bash
# Setup actions: bootstrap a Proxmox API account for a pipeline tool.
#
# action_setup_packer_account creates the Packer service account, role,
# template pool, and storage/pool/SDN ACLs on a Proxmox cluster using a
# one-time bootstrap admin token (e.g. root@pam!setup). The freshly minted
# API token is written to credentials.conf under the cluster's section so the
# rest of the console can use it immediately.
#
# Not strictly idempotent, but every step checks for the existing object
# and skips creation rather than failing. Re-runs are safe except for the
# final token-create step (a token of the same id can only exist once).

# Curl wrapper for the Proxmox API. Uses the currently exported
# PROXMOX_USERNAME/PROXMOX_TOKEN, which during setup hold the bootstrap
# admin token (not the soon-to-be-created Packer token).
# Echoes the raw response body; caller decides how to parse.
# Returns curl's exit code so callers can distinguish API errors.
_setup_api() {
  local method="$1" path="$2"
  shift 2
  curl -sf -k -X "$method" \
    -H "Authorization: PVEAPIToken=${PROXMOX_USERNAME}=${PROXMOX_TOKEN}" \
    "$@" \
    "${PROXMOX_URL}/api2/json${path}"
}

# Append a new [cluster] section to credentials.conf if it doesn't already exist.
# Creates the file with restrictive perms when missing so a fresh setup
# never produces a world-readable secrets file.
_setup_create_cluster_section() {
  local cluster="$1"
  local creds_file="${CONSOLE_DIR}/credentials.conf"
  if [[ ! -f "$creds_file" ]]; then
    touch "$creds_file"
    chmod 600 "$creds_file"
  fi
  if ! grep -qF "[${cluster}]" "$creds_file"; then
    printf '\n[%s]\n' "$cluster" >> "$creds_file"
  fi
}

# Insert or replace a key under a [cluster] section in credentials.conf.
# Mirrors config_set's INI-handling but writes to credentials.conf instead of
# console.cache. We deliberately don't reuse config_set since its file path and
# formatting (no spaces around =) differ from the credentials format.
_setup_credentials_set() {
  local cluster="$1" key="$2" value="$3"
  local creds_file="${CONSOLE_DIR}/credentials.conf"
  local section="[${cluster}]"

  if awk -v sec="$section" -v key="$key" '
    /^\[/ { in_sec = ($0 == sec) }
    in_sec && $0 ~ ("^[[:space:]]*"key"[[:space:]]*=") { found=1 }
    END { exit !found }
  ' "$creds_file"; then
    awk -v sec="$section" -v key="$key" -v val="$value" '
      /^\[/ { in_sec = ($0 == sec) }
      in_sec && $0 ~ ("^[[:space:]]*"key"[[:space:]]*=") { print key" = "val; next }
      { print }
    ' "$creds_file" > "${creds_file}.tmp" && mv "${creds_file}.tmp" "$creds_file"
  else
    awk -v sec="$section" -v line="${key} = ${value}" '
      { print }
      $0 == sec { print line }
    ' "$creds_file" > "${creds_file}.tmp" && mv "${creds_file}.tmp" "$creds_file"
  fi
  chmod 600 "$creds_file"
}

# Cluster picker for setup. Unlike proxmox_load_credentials, this does not
# attempt to load packer_username/packer_token (they may not exist yet —
# that's the whole point of running setup) and offers a "+ Create new"
# option so a fresh cluster can be bootstrapped end to end.
_setup_select_cluster() {
  mapfile -t clusters < <(_credentials_list_clusters)
  local -a options=()
  [[ ${#clusters[@]} -gt 0 ]] && options+=("${clusters[@]}")
  options+=("+ Create new cluster")

  PS3=$'\n  Select cluster to set up: '
  local selected
  select selected in "${options[@]}"; do
    [[ -n "$selected" ]] && break
    warn "Invalid selection."
  done

  if [[ "$selected" == "+ Create new cluster" ]]; then
    local name
    name="$(prompt "New cluster name (label only, e.g. home-lab)")"
    [[ -z "$name" ]] && die "Cluster name required."
    _setup_create_cluster_section "$name"
    PROXMOX_CLUSTER="$name"
  else
    PROXMOX_CLUSTER="$selected"
  fi
  config_set PROXMOX_CLUSTER "$PROXMOX_CLUSTER"
  success "Setting up cluster: ${PROXMOX_CLUSTER}"
  echo ""
}

# Read a config-cached value, or prompt with the given default and cache the
# result. Used for setup-time inputs (account name, role name, pool name)
# that we want to remember between runs of the setup action itself.
_setup_prompt_cached() {
  local key="$1" label="$2" default="$3"
  local saved value
  saved="$(config_get "$key")"
  value="$(prompt "$label" "${saved:-$default}")"
  [[ -z "$value" ]] && die "${label} is required."
  config_set "$key" "$value"
  echo "$value"
}

# Sanity-check the bootstrap credentials by hitting an endpoint that
# requires authentication. /version is the cheapest auth-gated call.
_setup_verify_bootstrap() {
  info "Verifying bootstrap credentials..."
  _setup_api GET /version >/dev/null \
    || die "Bootstrap credentials rejected by Proxmox. Check the token and try again."
  success "Bootstrap credentials accepted."
  echo ""
}

# Create the Packer user if it doesn't already exist. Idempotent: existing
# users are left untouched (we don't modify comments or other attributes
# since that could disrupt other tools sharing the account).
_setup_ensure_user() {
  local userid="$1"
  info "Ensuring user ${userid} exists..."
  local users
  users="$(_setup_api GET /access/users)" \
    || die "Failed to list users."
  if jq -e --arg u "$userid" '.data[] | select(.userid == $u)' <<< "$users" >/dev/null; then
    success "User ${userid} already exists — leaving as-is."
  else
    _setup_api POST /access/users \
      --data-urlencode "userid=${userid}" \
      --data-urlencode "comment=Packer Service Account (iron_bessy)" \
      >/dev/null \
      || die "Failed to create user ${userid}."
    success "Created user ${userid}."
  fi
  echo ""
}

# Create the role with the Packer privilege set. If the role already
# exists, warn but don't redefine it — the operator may have customized
# privs intentionally and we shouldn't silently overwrite that.
_setup_ensure_role() {
  local role="$1" privs="$2" label="${3:-}"
  info "Ensuring role ${role} exists..."
  local roles
  roles="$(_setup_api GET /access/roles)" \
    || die "Failed to list roles."
  if jq -e --arg r "$role" '.data[] | select(.roleid == $r)' <<< "$roles" >/dev/null; then
    warn "Role ${role} already exists — leaving privileges unchanged."
    warn "If privileges have drifted, delete the role in Proxmox and re-run setup."
  else
    _setup_api POST /access/roles \
      --data-urlencode "roleid=${role}" \
      --data-urlencode "privs=${privs}" \
      >/dev/null \
      || die "Failed to create role ${role}."
    success "Created role ${role}${label:+ with ${label} privileges}."
  fi
  echo ""
}

# Create the resource pool used to scope template ownership. Idempotent.
_setup_ensure_pool() {
  local pool="$1"
  info "Ensuring resource pool ${pool} exists..."
  local pools
  pools="$(_setup_api GET /pools)" \
    || die "Failed to list pools."
  if jq -e --arg p "$pool" '.data[] | select(.poolid == $p)' <<< "$pools" >/dev/null; then
    success "Pool ${pool} already exists — leaving as-is."
  else
    _setup_api POST /pools \
      --data-urlencode "poolid=${pool}" \
      --data-urlencode "comment=Packer template pool (iron_bessy)" \
      >/dev/null \
      || die "Failed to create pool ${pool}."
    success "Created pool ${pool}."
  fi
  echo ""
}

# Grant the role to the user on the given ACL path. PUT /access/acl is
# additive when called for a (path, user, role) triple that already exists,
# so retries are harmless.
_setup_grant_acl() {
  local path="$1" userid="$2" role="$3"
  info "Granting ${role} to ${userid} on ${path}..."
  _setup_api PUT /access/acl \
    --data-urlencode "path=${path}" \
    --data-urlencode "users=${userid}" \
    --data-urlencode "roles=${role}" \
    --data-urlencode "propagate=1" \
    >/dev/null \
    || die "Failed to set ACL on ${path}."
  success "ACL set on ${path}."
}

# Discover SDN zones via the API. Auto-selects when only one is present
# (the common single-cluster case where 'localnetwork' is the only zone),
# otherwise prompts. The result is cached per cluster so subsequent runs
# don't re-prompt.
_setup_select_sdn_zone() {
  local saved
  saved="$(config_get PROXMOX_SDN_ZONE)"

  info "Querying SDN zones..."
  local response
  response="$(_setup_api GET /cluster/sdn/zones)" \
    || die "Failed to query SDN zones."
  # /cluster/sdn/zones only lists user-configured SDN zones. The built-in
  # 'localnetwork' is a valid ACL path but isn't reported by this endpoint,
  # so fall back to it when the API returns nothing.
  mapfile -t zones < <(jq -r '.data[].zone' <<< "$response" | sort)
  [[ ${#zones[@]} -eq 0 ]] && zones=("localnetwork")

  if [[ -n "$saved" ]]; then
    local match
    for z in "${zones[@]}"; do [[ "$z" == "$saved" ]] && match=1 && break; done
    if [[ -n "${match:-}" ]]; then
      PROXMOX_SDN_ZONE="$saved"
      success "Using saved SDN zone: ${PROXMOX_SDN_ZONE}"
      echo ""
      return
    fi
    warn "Saved SDN zone '${saved}' no longer exists — please select again."
  fi

  if [[ ${#zones[@]} -eq 1 ]]; then
    PROXMOX_SDN_ZONE="${zones[0]}"
    success "Single SDN zone found, using: ${PROXMOX_SDN_ZONE}"
    echo ""
    config_set PROXMOX_SDN_ZONE "$PROXMOX_SDN_ZONE"
    return
  fi

  PS3=$'\n  Select SDN zone: '
  local selected
  select selected in "${zones[@]}"; do
    [[ -n "$selected" ]] && break
    warn "Invalid selection."
  done
  PROXMOX_SDN_ZONE="$selected"
  success "Selected SDN zone: ${PROXMOX_SDN_ZONE}"
  echo ""
  config_set PROXMOX_SDN_ZONE "$PROXMOX_SDN_ZONE"
}

# Create the API token under the Packer user and write the resulting
# secret into credentials.conf. This step is the one true non-idempotent part:
# Proxmox refuses to recreate an existing token (the secret can only be
# revealed at creation time), so we abort early with a clear message
# rather than silently leaving the operator without credentials.
_setup_create_token() {
  local userid="$1" tokenid="$2" cred_user_key="$3" cred_token_key="$4" comment="$5"
  info "Creating API token ${userid}!${tokenid}..."

  local existing
  existing="$(_setup_api GET "/access/users/${userid}/token")" \
    || die "Failed to list existing tokens for ${userid}."
  if jq -e --arg t "$tokenid" '.data[] | select(.tokenid == $t)' <<< "$existing" >/dev/null; then
    die "Token ${userid}!${tokenid} already exists.\nDelete it in Proxmox (Datacenter → Permissions → API Tokens) and re-run setup,\nor pick a different token id."
  fi

  local response
  response="$(_setup_api POST "/access/users/${userid}/token/${tokenid}" \
    --data-urlencode "comment=${comment}" \
    --data-urlencode "privsep=0")" \
    || die "Failed to create token."

  local secret full_id
  secret="$(jq -r '.data.value' <<< "$response")"
  full_id="$(jq -r '.data["full-tokenid"]' <<< "$response")"
  [[ -z "$secret" || "$secret" == "null" ]] && die "Proxmox response did not include a token secret."

  _setup_credentials_set "$PROXMOX_CLUSTER" "$cred_user_key"  "$full_id"
  _setup_credentials_set "$PROXMOX_CLUSTER" "$cred_token_key" "$secret"
  success "Token created and written to credentials.conf as ${cred_user_key} / ${cred_token_key}."
  echo ""
}

# Return " [done]" when all credential keys are present for the cluster,
# " [needed]" otherwise. Callers use this to annotate menu items so the
# operator can see at a glance what still needs to be run.
_setup_status_label() {
  local cluster="$1"; shift
  local key
  for key in "$@"; do
    local val
    val="$(_credentials_get "$cluster" "$key" 2>/dev/null)"
    [[ -z "$val" ]] && { echo " [needed]"; return; }
  done
  echo " [done]"
}

# Sub-menu for setup helpers. Keeps the top-level menu small as more
# bootstrap actions are added (e.g., per-tool service accounts).
action_setup_menu() {
  header "Setup"

  _setup_select_cluster

  while true; do
    local packer_label tofu_label
    packer_label="Packer service account$(_setup_status_label "$PROXMOX_CLUSTER" packer_username packer_token)"
    tofu_label="OpenTofu service account$(_setup_status_label "$PROXMOX_CLUSTER" tofu_username tofu_token)"

    local -a options=("$packer_label" "$tofu_label" "Back")
    PS3=$'\n  Setup action: '
    local choice
    select choice in "${options[@]}"; do
      [[ -n "$choice" ]] && break
      warn "Invalid selection."
    done
    echo ""

    case "$choice" in
      "$packer_label") (action_setup_packer_account) || true ;;
      "$tofu_label")   (action_setup_tofu_account) || true ;;
      "Back")          return 0 ;;
    esac
  done
}

action_setup_packer_account() {
  header "Setup — Packer Service Account"

  proxmox_prompt_url

  header "Bootstrap Credentials"
  info "Provide an existing admin API token (e.g. root@pam!setup) used"
  info "ONLY for this setup run. It is not written to disk."
  echo ""
  local bootstrap_user bootstrap_token
  bootstrap_user="$(prompt "Bootstrap username (e.g. root@pam!setup)")"
  [[ -z "$bootstrap_user" ]] && die "Bootstrap username required."
  bootstrap_token="$(prompt_secret "Bootstrap token secret")"
  [[ -z "$bootstrap_token" ]] && die "Bootstrap token required."
  echo ""

  PROXMOX_USERNAME="$bootstrap_user"
  PROXMOX_TOKEN="$bootstrap_token"
  _setup_verify_bootstrap

  header "Account Configuration"
  local packer_userid token_id role_name pool_name
  packer_userid="$(_setup_prompt_cached SETUP_PACKER_USERID  "Packer user id"  "packer@pve")"
  token_id="$(_setup_prompt_cached     SETUP_PACKER_TOKENID "Packer token id" "packer")"
  role_name="$(_setup_prompt_cached    SETUP_PACKER_ROLE    "Role name"       "PackerAutomation")"
  pool_name="$(_setup_prompt_cached    SETUP_PACKER_POOL    "Template pool"   "Templates")"
  echo ""

  header "Resource Discovery"
  proxmox_select_node
  proxmox_select_vm_storage  "$PROXMOX_NODE"
  proxmox_select_iso_storage "$PROXMOX_NODE"
  _setup_select_sdn_zone

  header "Summary"
  info "Cluster:       ${BOLD}${PROXMOX_CLUSTER}${RESET}"
  info "URL:           ${BOLD}${PROXMOX_URL}${RESET}"
  info "User / token:  ${BOLD}${packer_userid}!${token_id}${RESET}"
  info "Role:          ${BOLD}${role_name}${RESET}"
  info "Pool:          ${BOLD}${pool_name}${RESET}"
  info "VM storage:    ${BOLD}${PROXMOX_VM_STORAGE}${RESET}"
  info "ISO storage:   ${BOLD}${PROXMOX_ISO_STORAGE}${RESET}"
  info "SDN zone:      ${BOLD}${PROXMOX_SDN_ZONE}${RESET}"
  echo ""
  local confirm
  confirm="$(prompt "Proceed with setup? [y/N]")"
  [[ "${confirm,,}" != "y" ]] && { info "Aborted."; echo ""; return 0; }

  header "Provisioning"
  _setup_ensure_user "$packer_userid"
  _setup_ensure_role "$role_name" "$_SETUP_PACKER_PRIVS" "Packer"
  _setup_ensure_pool "$pool_name"
  _setup_grant_acl "/storage/${PROXMOX_VM_STORAGE}"  "$packer_userid" "$role_name"
  _setup_grant_acl "/storage/${PROXMOX_ISO_STORAGE}" "$packer_userid" "$role_name"
  _setup_grant_acl "/pool/${pool_name}"              "$packer_userid" "$role_name"
  _setup_grant_acl "/sdn/zones/${PROXMOX_SDN_ZONE}"  "$packer_userid" "$role_name"
  echo ""

  header "Token Issuance"
  _setup_create_token "$packer_userid" "$token_id" \
    "packer_username" "packer_token" "iron_bessy Packer token"

  success "Setup complete for cluster '${PROXMOX_CLUSTER}'."
  info "You can now run 'Build a VM template' against this cluster."
  echo ""
}

action_setup_tofu_account() {
  header "Setup — OpenTofu Service Account"

  proxmox_prompt_url

  header "Bootstrap Credentials"
  info "Provide an existing admin API token (e.g. root@pam!setup) used"
  info "ONLY for this setup run. It is not written to disk."
  echo ""
  local bootstrap_user bootstrap_token
  bootstrap_user="$(prompt "Bootstrap username (e.g. root@pam!setup)")"
  [[ -z "$bootstrap_user" ]] && die "Bootstrap username required."
  bootstrap_token="$(prompt_secret "Bootstrap token secret")"
  [[ -z "$bootstrap_token" ]] && die "Bootstrap token required."
  echo ""

  PROXMOX_USERNAME="$bootstrap_user"
  PROXMOX_TOKEN="$bootstrap_token"
  _setup_verify_bootstrap

  header "Account Configuration"
  local tofu_userid token_id role_name
  tofu_userid="$(_setup_prompt_cached SETUP_TOFU_USERID  "OpenTofu user id"  "terraform@pve")"
  token_id="$(_setup_prompt_cached    SETUP_TOFU_TOKENID "OpenTofu token id" "terraform")"
  role_name="$(_setup_prompt_cached   SETUP_TOFU_ROLE    "Role name"         "TerraformAutomation")"
  echo ""

  header "Summary"
  info "Cluster:       ${BOLD}${PROXMOX_CLUSTER}${RESET}"
  info "URL:           ${BOLD}${PROXMOX_URL}${RESET}"
  info "User / token:  ${BOLD}${tofu_userid}!${token_id}${RESET}"
  info "Role:          ${BOLD}${role_name}${RESET}"
  info "ACL scope:     ${BOLD}/${RESET} (cluster-wide)"
  echo ""
  warn "The role grants Sys.Modify cluster-wide so OpenTofu can manage"
  warn "cluster firewall security groups. If you don't manage those in tofu,"
  warn "edit the role in Proxmox afterward to drop Sys.Audit + Sys.Modify."
  echo ""
  local confirm
  confirm="$(prompt "Proceed with setup? [y/N]")"
  [[ "${confirm,,}" != "y" ]] && { info "Aborted."; echo ""; return 0; }

  header "Provisioning"
  _setup_ensure_user "$tofu_userid"
  _setup_ensure_role "$role_name" "$_SETUP_TOFU_PRIVS" "OpenTofu"
  _setup_grant_acl "/" "$tofu_userid" "$role_name"
  echo ""

  header "Token Issuance"
  _setup_create_token "$tofu_userid" "$token_id" \
    "tofu_username" "tofu_token" "iron_bessy OpenTofu token"

  success "Setup complete for cluster '${PROXMOX_CLUSTER}'."
  echo ""
}
