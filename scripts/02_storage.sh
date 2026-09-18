#!/usr/bin/env bash
# Stage 2 — point ComfyUI's model directories at the persistent model store.
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"
source "${WD_REPO_DIR}/scripts/paths.sh"

section "Stage 2/6 — storage layout"

log "ComfyUI:      ${COMFY_DIR}"
log "model store:  ${WD_MODEL_ROOT}"

# This template is built for infrequent use: no volume is the expected setup,
# and models are re-fetched in parallel on each boot instead of paying for
# idle storage. A volume is still used when one happens to be attached, which
# makes the boot nearly instant.
if [[ "${WD_MODELS_PERSISTENT}" == "1" ]]; then
  ok "volume detected at ${WD_PERSIST_ROOT:-/workspace} — models are cached"
  ok "across pod stops, so this boot only fetches what is missing"
else
  log "no volume attached — models go to the container disk and are re-fetched"
  log "on each boot (by design for occasional use; attach a 100 GB volume at"
  log "${WD_PERSIST_ROOT:-/workspace} if you would rather cache them)"
fi

mkdir -p "${WD_MODEL_ROOT}"
AVAIL="$(free_gib "${WD_MODEL_ROOT}" || echo 0)"
log "free space at model store: ${AVAIL:-?} GiB"
if [[ -n "${AVAIL}" && "${AVAIL}" -lt 60 ]]; then
  warn "less than 60 GiB free — the full model set needs roughly 45 GiB plus"
  warn "room for output video; downloads may fail part-way through."
  warn "Raise the RunPod Container disk (80 GB is a good figure)."
fi

# Redirect each model subdirectory onto the store via symlink. ComfyUI resolves
# symlinks fine, and this keeps the image's own directory layout untouched.
for sub in "${WD_MODEL_SUBDIRS[@]}"; do
  link_dir "${WD_MODEL_ROOT}/${sub}" "${COMFY_DIR}/models/${sub}"
  log "  models/${sub} -> ${WD_MODEL_ROOT}/${sub}"
done

# Outputs and the input folder are worth keeping across restarts too.
if [[ "${WD_MODELS_PERSISTENT}" == "1" ]]; then
  link_dir "${WD_PERSIST_ROOT:-/workspace}/wan-dancer/output" "${COMFY_DIR}/output"
  link_dir "${WD_PERSIST_ROOT:-/workspace}/wan-dancer/input"  "${COMFY_DIR}/input"
  log "  output/ and input/ also persisted"
fi

# Keep the HuggingFace cache on the same filesystem as the store, otherwise the
# download lands on the container disk first and doubles the space needed.
export HF_HOME="${WD_MODEL_ROOT%/models}/hf-cache"
mkdir -p "$HF_HOME"
log "HF_HOME=${HF_HOME}"

ok "stage 2 complete"
