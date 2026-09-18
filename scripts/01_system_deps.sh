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

# Download acceleration. Which package provides it depends on the
# huggingface_hub major version, and the wrong one is simply inert:
#   1.x -> Xet (hf_xet) is the chunked, multi-connection backend
#   0.x -> hf_transfer is the Rust multi-connection downloader
# huggingface_hub itself is deliberately NOT upgraded by default: the image's
# transformers build may pin it below 1.0, and breaking that to gain a faster
# downloader is a bad trade. Set WD_UPGRADE_HF_HUB=1 to opt in.
log "installing Python download tooling"

PY="$(python_bin)"
log "python: ${PY}"

if ! "$PY" -c 'import huggingface_hub' >/dev/null 2>&1; then
  log "huggingface_hub missing — installing"
  pip_install huggingface_hub || die "could not install huggingface_hub"
elif [[ "${WD_UPGRADE_HF_HUB:-0}" == "1" ]]; then
  log "WD_UPGRADE_HF_HUB=1 — upgrading huggingface_hub"
  pip_install huggingface_hub || warn "upgrade failed; keeping the existing version"
fi

HUB_VERSION="$("$PY" -c 'from importlib.metadata import version; print(version("huggingface_hub"))' 2>/dev/null || echo 0)"
HUB_MAJOR="${HUB_VERSION%%.*}"
log "huggingface_hub ${HUB_VERSION}"

if [[ "${HUB_MAJOR:-0}" -ge 1 ]]; then
  if "$PY" -c 'import hf_xet' >/dev/null 2>&1; then
    ok "hf_xet present — parallel Xet transfers available"
  else
    log "installing hf_xet for parallel chunked downloads"
    pip_install hf_xet || warn "hf_xet install failed; downloads fall back to plain HTTPS (slower)"
  fi
else
  if "$PY" -c 'import hf_transfer' >/dev/null 2>&1; then
    ok "hf_transfer present — parallel transfers available"
  else
    log "installing hf_transfer for parallel chunked downloads"
    pip_install hf_transfer || warn "hf_transfer install failed; downloads fall back to plain HTTPS (slower)"
  fi
fi

mark_done system_deps
ok "stage 1 complete"
