#!/usr/bin/env bash
# Stage 1 — OS packages and Python tooling the download/render path needs.
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"

section "Stage 1/6 — system dependencies"

if is_done system_deps && [[ "${WD_FORCE:-0}" != "1" ]]; then
  ok "already installed (state marker present)"
  exit 0
fi

# ffmpeg is what ComfyUI shells out to for muxing the rendered frames with the
# audio track; without it video export silently produces frames only.
PACKAGES=(ffmpeg git git-lfs aria2 curl ca-certificates)
MISSING=()
for pkg in "${PACKAGES[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done

if (( ${#MISSING[@]} )); then
  log "installing: ${MISSING[*]}"
  export DEBIAN_FRONTEND=noninteractive
  if retry 3 apt-get update -qq; then
    retry 3 apt-get install -y -qq --no-install-recommends "${MISSING[@]}" \
      || warn "apt-get install failed; continuing (ffmpeg may already be vendored in the image)"
  else
    warn "apt-get update failed; skipping OS packages"
  fi
else
  ok "all OS packages present"
fi

command -v ffmpeg >/dev/null 2>&1 \
  && ok "ffmpeg: $(ffmpeg -version 2>/dev/null | head -1)" \
  || warn "ffmpeg not on PATH — video muxing with audio will fail"

git lfs install --skip-repo >/dev/null 2>&1 || true

# hf_transfer gives a multi-threaded Rust download path; the two 16 GB experts
# are the bulk of setup time and this roughly halves it.
log "installing Python download tooling"
pip_install "huggingface_hub[hf_transfer]" || die "could not install huggingface_hub"

mark_done system_deps
ok "stage 1 complete"
