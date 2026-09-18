#!/usr/bin/env bash
# Stage 5 — download the Wan-Dancer weights and every companion encoder.
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"

section "Stage 5/6 — model download"

WD_GROUPS="${WD_MODEL_GROUPS:-core,speed}"
if [[ "${WD_DOWNLOAD_OPTIONAL:-0}" == "1" ]]; then
  WD_GROUPS="${WD_GROUPS},optional"
fi

# hf_transfer is a large win on the two ~16 GB expert checkpoints.
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export HF_HOME="${HF_HOME:-${WD_MODEL_ROOT%/models}/hf-cache}"
mkdir -p "$HF_HOME"

if [[ -n "${HF_TOKEN:-}" ]]; then
  log "HF_TOKEN is set — gated repos are reachable"
else
  log "no HF_TOKEN set (fine unless a repo later becomes gated)"
fi

log "groups: ${WD_GROUPS}"
log "destination: ${COMFY_DIR}/models"
log "this is the slow part — expect 15-40 minutes on a cold volume"

PY="$(python_bin)"
if "$PY" "${WD_REPO_DIR}/scripts/download.py" \
      --manifest "${WD_REPO_DIR}/config/models.tsv" \
      --models-root "${COMFY_DIR}/models" \
      --groups "${WD_GROUPS}"
then
  mark_done models
  ok "stage 5 complete — all core models present"
else
  err "one or more CORE models are missing; ComfyUI will start but"
  err "Wan-Dancer generation will fail until they are downloaded."
  err "Re-run with:  bash ${WD_REPO_DIR}/setup.sh --models-only"
  exit 1
fi
