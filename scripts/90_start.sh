#!/usr/bin/env bash
# Final stage — hand the container a long-running foreground process.
#
# The RunPod "Container start command" replaces the image's own CMD, so nothing
# else is going to launch the server: if this script returns, the pod stops.
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"

section "Starting ComfyUI"

PORT="${WD_COMFY_PORT:-8188}"
HOST="${WD_COMFY_HOST:-0.0.0.0}"

# Some people prefer the base image's supervisor (JupyterLab, file browser and
# friends). Opt into it with WD_USE_IMAGE_ENTRYPOINT=1.
if [[ "${WD_USE_IMAGE_ENTRYPOINT:-0}" == "1" ]]; then
  for candidate in /start.sh /pre_start.sh /opt/start.sh /usr/local/bin/start.sh; do
    if [[ -x "$candidate" ]]; then
      log "handing off to the image entrypoint: ${candidate}"
      exec "$candidate"
    fi
  done
  warn "WD_USE_IMAGE_ENTRYPOINT=1 but no image start script found; starting ComfyUI directly"
fi

cd "${COMFY_DIR}"
PY="$(python_bin)"

ARGS=( main.py --listen "$HOST" --port "$PORT" )

# 14B at 149 frames is heavy. Let the caller pick, but default to the setting
# that keeps a 24 GB card from OOMing mid-sample.
case "${WD_VRAM_MODE:-auto}" in
  highvram)   ARGS+=( --highvram ) ;;
  normalvram) ARGS+=( --normalvram ) ;;
  lowvram)    ARGS+=( --lowvram ) ;;
  auto)
    TOTAL_GIB="$("$PY" -c 'import torch;print(int(torch.cuda.get_device_properties(0).total_memory/2**30)) if torch.cuda.is_available() else print(0)' 2>/dev/null || echo 0)"
    log "detected ${TOTAL_GIB} GiB of VRAM"
    if   (( TOTAL_GIB >= 70 )); then ARGS+=( --highvram )
    elif (( TOTAL_GIB >= 40 )); then ARGS+=( --normalvram )
    elif (( TOTAL_GIB >  0 ));  then ARGS+=( --lowvram )
                                     warn "under 40 GiB of VRAM — expect offloading and slow sampling"
    fi
    ;;
esac

if [[ -n "${WD_COMFY_EXTRA_ARGS:-}" ]]; then
  read -r -a EXTRA <<< "${WD_COMFY_EXTRA_ARGS}"
  ARGS+=( "${EXTRA[@]}" )
fi

ok "ComfyUI will be reachable on the pod's HTTP port ${PORT}"
log "launching: ${PY} ${ARGS[*]}"

exec "$PY" "${ARGS[@]}"
