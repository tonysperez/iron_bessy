#!/usr/bin/env bash
# Load Proxmox privilege sets from the editable .conf files at the console root.
# Edit console/packer.conf and console/tofu.conf to change role permissions.

_load_privs() {
  local file="$1"
  [[ ! -f "$file" ]] && die "Privilege file not found: ${file}"
  grep -v '^\s*#' "$file" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//'
}

_SETUP_PACKER_PRIVS="$(_load_privs "${CONSOLE_DIR}/hypervisor-privs-packer.conf")"
_SETUP_TOFU_PRIVS="$(_load_privs "${CONSOLE_DIR}/hypervisor-privs-tofu.conf")"
