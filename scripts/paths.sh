#!/usr/bin/env bash
# Locates ComfyUI and decides where models live. Sourced by setup.sh, which
# exports the result so every stage script agrees on the layout.

# ------------------------------------------------------------- ComfyUI dir ----
# The runpod/comfyui image has moved ComfyUI around between releases, so probe
# the known locations instead of hardcoding one.
detect_comfy_dir() {
  if [[ -n "${COMFY_DIR:-}" && -f "${COMFY_DIR}/main.py" ]]; then
    echo "$COMFY_DIR"; return 0
  fi

  local candidate
  for candidate in \
    /ComfyUI \
    /comfyui \
    /workspace/ComfyUI \
    /workspace/comfyui \
    /opt/ComfyUI \
    /app/ComfyUI \
    /root/ComfyUI
  do
    [[ -f "${candidate}/main.py" ]] && { echo "$candidate"; return 0; }
  done

  # Last resort: search the shallow levels of the usual roots.
  candidate="$(find / /workspace /opt /app -maxdepth 3 -name main.py -path '*omfy*' \
                 -not -path '*/custom_nodes/*' 2>/dev/null | head -1)"
  [[ -n "$candidate" ]] && { dirname "$candidate"; return 0; }

  return 1
}

# ------------------------------------------------------------- model store ----
# Models must survive a pod stop, which means they belong on the volume mounted
# at /workspace. When no volume is attached (RunPod "Volume disk: 0 GB") the
# container disk is the only option — usable, but wiped on stop, so we say so
# loudly rather than silently re-downloading 45 GB on every start.
resolve_model_root() {
  local persist_root="${WD_PERSIST_ROOT:-/workspace}"

  if [[ -n "${WD_MODEL_ROOT:-}" ]]; then
    echo "$WD_MODEL_ROOT"
    return 0
  fi

  if is_persistent_mount "$persist_root"; then
    echo "${persist_root}/wan-dancer/models"
    return 0
  fi

  # /workspace exists but is part of the container filesystem.
  echo "${WD_FALLBACK_MODEL_ROOT:-/comfy-models}"
  return 1
}

# ComfyUI model subdirectories that we redirect onto the model store.
WD_MODEL_SUBDIRS=(
  diffusion_models
  text_encoders
  clip_vision
  vae
  audio_encoders
  loras
)
