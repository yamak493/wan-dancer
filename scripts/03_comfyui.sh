#!/usr/bin/env bash
# Stage 3 — make sure ComfyUI itself is new enough to have the native Wan
# Dancer nodes (WanDancer* / audio encoder loader).
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"

section "Stage 3/6 — ComfyUI"

cd "${COMFY_DIR}"

if [[ "${WD_UPDATE_COMFYUI:-1}" != "1" ]]; then
  log "WD_UPDATE_COMFYUI=0 — leaving the image's ComfyUI untouched"
elif [[ -d .git ]]; then
  log "updating ComfyUI to the latest release"
  if retry 4 git fetch --tags origin; then
    DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')"
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"
    git checkout "${DEFAULT_BRANCH}" >/dev/null 2>&1 || warn "could not check out ${DEFAULT_BRANCH}"
    git pull --ff-only origin "${DEFAULT_BRANCH}" || warn "fast-forward pull failed; keeping current revision"
  else
    warn "git fetch failed; keeping the bundled ComfyUI revision"
  fi
  log "ComfyUI revision: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
else
  warn "${COMFY_DIR} is not a git checkout — cannot update it"
  warn "if Wan-Dancer nodes are missing, rebuild from a newer base image"
fi

if [[ -f requirements.txt ]]; then
  log "reconciling ComfyUI Python requirements"
  pip_install -r requirements.txt || warn "some requirements failed to install"
fi

# Wan-Dancer conditions on audio, so ComfyUI needs a working torchaudio to load
# the music track. Verify rather than assume.
PY="$(python_bin)"
"$PY" - <<'PYCHECK' || warn "audio stack check failed — see above"
import sys
try:
    import torch
    print(f"[check] torch {torch.__version__}  cuda={torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"[check] gpu: {torch.cuda.get_device_name(0)}  "
              f"{torch.cuda.get_device_properties(0).total_memory / 2**30:.1f} GiB")
except Exception as exc:
    print(f"[check] torch unavailable: {exc}", file=sys.stderr)
    raise SystemExit(1)
try:
    import torchaudio
    print(f"[check] torchaudio {torchaudio.__version__}")
except Exception as exc:
    print(f"[check] torchaudio missing ({exc}) — audio loading will fail", file=sys.stderr)
PYCHECK

ok "stage 3 complete"
