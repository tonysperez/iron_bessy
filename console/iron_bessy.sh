#!/usr/bin/env bash
# iron_bessy — IaC Pipeline Console
# Main entrypoint. Source modules from shared/ to add new pipeline stages.

set -euo pipefail

CONSOLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CONSOLE_DIR}/.." && pwd)"
PACKER_DIR="${REPO_ROOT}/packer"

source "${CONSOLE_DIR}/shared/output.sh"
source "${CONSOLE_DIR}/shared/config.sh"
source "${CONSOLE_DIR}/shared/proxmox.sh"
source "${CONSOLE_DIR}/shared/packer.sh"

# ── Argument parsing ───────────────────────────────────────────────────────────
_usage() {
  cat <<EOF
iron_bessy — IaC Pipeline Console

Usage: $(basename "${BASH_SOURCE[0]}") [options]

Options:
  --no-cache    Prompt for every input; cached values are shown as defaults.
  -h, --help    Show this help and exit.

See console/README.md for the full workflow.
EOF
}

NO_CACHE=0
for _arg in "$@"; do
  case "$_arg" in
    --no-cache)  NO_CACHE=1 ;;
    -h|--help)   _usage; exit 0 ;;
    *)           error "Unknown argument: ${_arg}"; _usage >&2; exit 1 ;;
  esac
done
unset _arg

# ── Signal handling ────────────────────────────────────────────────────────────
_on_interrupt() {
  echo ""
  warn "Interrupted."
  echo ""
  exit 130
}
trap '_on_interrupt' INT TERM

# ── Main menu ──────────────────────────────────────────────────────────────────
main() {
  header "iron_bessy — IaC Pipeline Console"
  echo ""

  # Register actions here as the pipeline grows.
  local -a actions=(
    "Build a VM template"
    "Quit"
    # Add new actions here
  )

  PS3=$'\n  Action: '
  select action in "${actions[@]}"; do
    case "$action" in
      "Build a VM template") action_build_template; break ;;
      "Quit")                info "Goodbye."; echo ""; exit 0 ;;
      *)                     warn "Invalid selection." ;;
    esac
  done
}

main
