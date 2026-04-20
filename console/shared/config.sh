#!/usr/bin/env bash
# Persistent local config cache. Supports INI-style format with sections.
#
# STRUCTURE:
# - PROXMOX_CLUSTER is always at the top level (no section header)
# - All other config keys are stored under [PROXMOX_CLUSTER] sections
# - This allows multiple clusters to have independent cached values
#
# Example:
#   PROXMOX_CLUSTER=home-lab
#   [home-lab]
#   PROXMOX_NODE=pve
#   PROXMOX_URL=https://...
#   [work]
#   PROXMOX_NODE=pve-work
#   PROXMOX_URL=https://...

CONFIG_FILE="${CONSOLE_DIR}/.config"

# Returns true if a key should always be stored at the global (unsectioned) level.
_config_is_global() { [[ "$1" == "PROXMOX_CLUSTER" ]]; }

config_get() {
  local key="$1"
  [[ ! -f "$CONFIG_FILE" ]] && echo "" && return

  if _config_is_global "$key" || [[ -z "${PROXMOX_CLUSTER:-}" ]]; then
    # Global keys (like PROXMOX_CLUSTER): read from top level
    grep "^${key}=" "$CONFIG_FILE" | cut -d= -f2- | head -1
  else
    # Cluster-scoped keys: read from the [CLUSTER] section
    # awk logic: track section entry, match key in section, extract value after =
    awk -v sec="[${PROXMOX_CLUSTER}]" -v key="$key" '
      /^\[/ { in_sec = ($0 == sec) }
      in_sec && $0 ~ ("^"key"=") { sub(/^[^=]*=/, ""); print; exit }
    ' "$CONFIG_FILE"
  fi
}

config_set() {
  local key="$1" value="$2"

  if _config_is_global "$key" || [[ -z "${PROXMOX_CLUSTER:-}" ]]; then
    if [[ -f "$CONFIG_FILE" ]] && grep -q "^${key}=" "$CONFIG_FILE"; then
      awk -v key="$key" -v val="$value" '
        $0 ~ ("^"key"=") { print key"="val; next }
        { print }
      ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
      echo "${key}=${value}" >> "$CONFIG_FILE"
    fi
    return
  fi

  local section="[${PROXMOX_CLUSTER}]"
  local entry="${key}=${value}"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf '\n%s\n%s\n' "$section" "$entry" > "$CONFIG_FILE"
    return
  fi

  if grep -qF "$section" "$CONFIG_FILE"; then
    if awk -v sec="$section" -v key="$key" '
      /^\[/ { in_sec = ($0 == sec) }
      in_sec && $0 ~ ("^"key"=") { found=1 }
      END { exit !found }
    ' "$CONFIG_FILE"; then
      awk -v sec="$section" -v key="$key" -v val="$value" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && $0 ~ ("^"key"=") { print key"="val; next }
        { print }
      ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
      awk -v sec="$section" -v entry="$entry" '
        { print }
        $0 == sec { print entry }
      ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
  else
    printf '\n%s\n%s\n' "$section" "$entry" >> "$CONFIG_FILE"
  fi
}
