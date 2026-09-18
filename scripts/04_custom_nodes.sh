#!/usr/bin/env bash
# Stage 4 — quality-of-life custom nodes. Wan-Dancer runs on native nodes, so
# nothing here is load-bearing; failures are warnings, never fatal.
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"

section "Stage 4/6 — custom nodes"

if [[ "${WD_INSTALL_CUSTOM_NODES:-1}" != "1" ]]; then
  log "WD_INSTALL_CUSTOM_NODES=0 — skipping"
  exit 0
fi

NODES_DIR="${COMFY_DIR}/custom_nodes"
mkdir -p "${NODES_DIR}"
LIST="${WD_REPO_DIR}/config/custom_nodes.txt"
[[ -f "$LIST" ]] || { warn "no ${LIST}; skipping"; exit 0; }

while IFS=$'\t' read -r url branch || [[ -n "$url" ]]; do
  url="${url%%#*}"; url="$(echo "$url" | xargs)"
  [[ -z "$url" ]] && continue

  name="$(basename "$url" .git)"
  target="${NODES_DIR}/${name}"

  if [[ -d "${target}/.git" ]]; then
    log "updating ${name}"
    git -C "$target" pull --ff-only >/dev/null 2>&1 || warn "could not update ${name}"
  else
    log "cloning ${name}"
    if [[ -n "${branch:-}" ]]; then
      retry 3 git clone --depth 1 --branch "$branch" "$url" "$target" \
        || { warn "clone failed: ${name}"; continue; }
    else
      retry 3 git clone --depth 1 "$url" "$target" \
        || { warn "clone failed: ${name}"; continue; }
    fi
  fi

  if [[ -f "${target}/requirements.txt" ]]; then
    pip_install -r "${target}/requirements.txt" \
      || warn "requirements for ${name} failed; the node may not load"
  fi
done < "$LIST"

ok "stage 4 complete"
