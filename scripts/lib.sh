#!/usr/bin/env bash
# Shared helpers for the Wan-Dancer RunPod bootstrap scripts.
# Sourced by every script; never executed directly.

# ---------------------------------------------------------------- logging ----
_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log()  { printf '\033[0;36m[%s] [wan-dancer]\033[0m %s\n' "$(_ts)" "$*" >&2; }
warn() { printf '\033[0;33m[%s] [wan-dancer] WARN:\033[0m %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '\033[0;31m[%s] [wan-dancer] ERROR:\033[0m %s\n' "$(_ts)" "$*" >&2; }
ok()   { printf '\033[0;32m[%s] [wan-dancer] OK:\033[0m %s\n' "$(_ts)" "$*" >&2; }

section() {
  printf '\n\033[1;35m========================================================\033[0m\n' >&2
  printf '\033[1;35m  %s\033[0m\n' "$*" >&2
  printf '\033[1;35m========================================================\033[0m\n' >&2
}

die() { err "$*"; exit 1; }

# ------------------------------------------------------------------ retry ----
# retry <attempts> <cmd...> — exponential backoff 2s, 4s, 8s, 16s ...
retry() {
  local attempts="$1"; shift
  local n=1 delay=2
  until "$@"; do
    if (( n >= attempts )); then
      err "command failed after ${attempts} attempts: $*"
      return 1
    fi
    warn "attempt ${n}/${attempts} failed, retrying in ${delay}s: $*"
    sleep "$delay"
    n=$(( n + 1 ))
    delay=$(( delay * 2 ))
  done
  return 0
}

# ------------------------------------------------------------- filesystem ----
# is_persistent_mount <path> — true when <path> sits on a different device than
# the container root, i.e. a RunPod volume/network disk is actually attached.
is_persistent_mount() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  local dev_path dev_root
  dev_path="$(stat -c '%d' "$path" 2>/dev/null)" || return 1
  dev_root="$(stat -c '%d' / 2>/dev/null)" || return 1
  [[ "$dev_path" != "$dev_root" ]]
}

# free_gib <path> — free space in GiB on the filesystem holding <path>
free_gib() {
  df -B1G --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '
}

# link_dir <source_dir> <link_path> — make <link_path> point at <source_dir>.
# Migrates any pre-existing real directory's contents into the source first so
# that models shipped inside the image are not lost.
link_dir() {
  local src="$1" link="$2"
  mkdir -p "$src"

  if [[ -L "$link" ]]; then
    local current
    current="$(readlink -f "$link")"
    [[ "$current" == "$(readlink -f "$src")" ]] && return 0
    rm -f "$link"
  elif [[ -d "$link" ]]; then
    if [[ -n "$(ls -A "$link" 2>/dev/null)" ]]; then
      log "migrating existing contents of ${link} -> ${src}"
      cp -a "${link}/." "${src}/" 2>/dev/null || warn "could not migrate ${link}"
    fi
    rm -rf "$link"
  fi

  mkdir -p "$(dirname "$link")"
  ln -sfn "$src" "$link"
}

# ----------------------------------------------------------------- python ----
# python_bin — the interpreter ComfyUI actually runs under.
#
# This matters more than it looks: several ComfyUI images run the server from a
# virtualenv. Installing into a bare `python3` there would put huggingface_hub
# and the custom-node requirements somewhere ComfyUI never imports from, and
# the failure only shows up later as a missing node.
python_bin() {
  if [[ -n "${COMFY_PYTHON:-}" && -x "${COMFY_PYTHON}" ]]; then
    echo "$COMFY_PYTHON"; return 0
  fi

  # An already-active virtualenv wins.
  if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
    echo "${VIRTUAL_ENV}/bin/python"; return 0
  fi

  local candidate
  for candidate in \
    "${COMFY_DIR:-/nonexistent}/venv/bin/python" \
    "${COMFY_DIR:-/nonexistent}/.venv/bin/python" \
    /venv/bin/python \
    /workspace/venv/bin/python \
    /opt/venv/bin/python
  do
    [[ -x "$candidate" ]] && { echo "$candidate"; return 0; }
  done

  command -v python3 || command -v python
}

pip_install() {
  local py; py="$(python_bin)"
  retry 3 "$py" -m pip install --no-cache-dir --upgrade "$@"
}

# ------------------------------------------------------------------ state ----
# State markers let a restarted pod skip work that already completed.
state_dir() { echo "${WD_STATE_DIR:-/workspace/.wan-dancer}"; }

mark_done()  { mkdir -p "$(state_dir)"; date -u '+%Y-%m-%dT%H:%M:%SZ' > "$(state_dir)/$1.done"; }
is_done()    { [[ -f "$(state_dir)/$1.done" ]]; }
