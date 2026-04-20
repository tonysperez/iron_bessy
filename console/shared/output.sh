#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared output and UI helpers: logging, colored output, and user prompts.
#
# All functions respect NO_COLOR env var (POSIX standard) to disable ANSI colors.
# Output functions (header, info, warn, success, error) write to stdout or stderr.
# The prompt() function reads from stdin and can be used in command substitution.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

header()  { echo -e "\n${BOLD}${BLUE}══ $* ══${RESET}"; }
info()    { echo -e "  ${CYAN}[*]${RESET} $*"; }
success() { echo -e "  ${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "  ${RED}[-]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

prompt() {
  local msg="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${msg}${RESET} [${default}]: " >&2
  else
    echo -ne "  ${BOLD}${msg}${RESET}: " >&2
  fi
  local val
  read -r val
  echo "${val:-$default}"
}