#!/usr/bin/env bash
# Stage 5 — download the Wan-Dancer weights and every companion encoder.
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"

section "Stage 5/6 — model download"

WD_GROUPS="${WD_MODEL_GROUPS:-core,speed}"
if [[ "${WD_DOWNLOAD_OPTIONAL:-0}" == "1" ]]; then
  WD_GROUPS="${WD_GROUPS},optional"
fi

# download.py picks and enables the right accelerator itself (Xet on
# huggingface_hub 1.x, hf_transfer on 0.x) — it has to happen before the
# library is imported, so it is not set here.
CONCURRENCY="${WD_DOWNLOAD_CONCURRENCY:-4}"

# Keep the HF cache beside the models so a partial transfer cannot fill a
# different filesystem than the one we checked for free space.
export HF_HOME="${HF_HOME:-${WD_MODEL_ROOT%/models}/hf-cache}"
mkdir -p "$HF_HOME"

if [[ -n "${HF_TOKEN:-}" ]]; then
  log "HF_TOKEN is set — gated repos are reachable"
else
  log "no HF_TOKEN set (fine unless a repo later becomes gated)"
fi

log "groups: ${WD_GROUPS}"
log "destination: ${COMFY_DIR}/models"
log "concurrent transfers: ${CONCURRENCY}"
log "this is the slow part — roughly 45 GiB; wall time depends on the pod's"
log "network, typically 5-15 minutes on a well-connected RunPod region"

PY="$(python_bin)"
if "$PY" "${WD_REPO_DIR}/scripts/download.py" \
      --manifest "${WD_REPO_DIR}/config/models.tsv" \
      --models-root "${COMFY_DIR}/models" \
      --groups "${WD_GROUPS}" \
      --concurrency "${CONCURRENCY}"
then
  mark_done models
  ok "stage 5 complete — all core models present"
else
  err "one or more CORE models are missing; ComfyUI will start but"
  err "Wan-Dancer generation will fail until they are downloaded."
  err "Re-run with:  bash ${WD_REPO_DIR}/setup.sh --models-only"
  exit 1
fi
