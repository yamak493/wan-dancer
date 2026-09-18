#!/usr/bin/env bash
# Bash-side wrappers for the setup status file (scripts/wd_status.py).
# Sourced by lib.sh, so every stage script gets these for free.
#
# Every function is a no-op when the status page is disabled or python3 is
# missing: progress reporting must never be able to fail a boot.

status_file() { echo "${WD_STATUS_DIR:-/tmp/wan-dancer}/status.json"; }

_status_enabled() {
  [[ "${WD_STATUS_PAGE:-1}" != "0" ]] && command -v python3 >/dev/null 2>&1
}

_status_py() {
  _status_enabled || return 0
  python3 "${WD_REPO_DIR}/scripts/wd_status.py" "$(status_file)" "$@" 2>/dev/null || true
}

status_init()  { _status_py init; }
status_stage() { _status_py stage "$1" "$2"; }
status_set()   { _status_py set "$1" "$2"; }
status_append(){ _status_py append "$1" "$2"; }
