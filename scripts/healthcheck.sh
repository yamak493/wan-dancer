#!/usr/bin/env bash
# Prints a readiness report: which model files landed, and whether this
# ComfyUI build actually exposes the native Wan-Dancer nodes.
# Safe to run any time, including from a pod terminal after startup.
set -uo pipefail
source "${WD_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib.sh"

: "${COMFY_DIR:?COMFY_DIR must be set (run this via setup.sh, or export it)}"

section "Readiness check"

MODELS="${COMFY_DIR}/models"
MISSING=0

check_any() {
  local subdir="$1" pattern="$2" label="$3"
  local found
  found="$(find -L "${MODELS}/${subdir}" -maxdepth 1 -iname "$pattern" 2>/dev/null | head -1)"
  if [[ -n "$found" ]]; then
    local size
    size="$(du -h "$found" 2>/dev/null | cut -f1)"
    ok "$(printf '%-22s %s (%s)' "$label" "$(basename "$found")" "$size")"
  else
    err "$(printf '%-22s MISSING  (models/%s/%s)' "$label" "$subdir" "$pattern")"
    MISSING=$(( MISSING + 1 ))
  fi
}

check_any diffusion_models '*dancer*global*.safetensors' 'dancer global expert'
check_any diffusion_models '*dancer*local*.safetensors'  'dancer local expert'
check_any text_encoders    'umt5_xxl*.safetensors'       'text encoder'
check_any clip_vision      'clip_vision_h*.safetensors'  'clip vision'
check_any vae              '*vae*.safetensors'           'wan 2.1 vae'
check_any audio_encoders   'wav2vec2*.safetensors'       'audio encoder'

found_lora="$(find -L "${MODELS}/loras" -maxdepth 1 -iname '*lightx2v*.safetensors' 2>/dev/null | head -1)"
[[ -n "$found_lora" ]] \
  && ok "$(printf '%-22s %s' 'lightning lora' "$(basename "$found_lora")")" \
  || warn "$(printf '%-22s not present (optional; sampling will use full steps)' 'lightning lora')"

# Does this ComfyUI know the Wan-Dancer nodes at all? An up-to-date node
# registry is the other half of "ready"; an old image silently lacks them.
section "ComfyUI node support"
PY="$(python_bin)"
( cd "${COMFY_DIR}" && "$PY" - <<'PYEOF'
import sys, io, contextlib
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        import nodes
        nodes.init_extra_nodes(init_custom_nodes=False)
    names = list(nodes.NODE_CLASS_MAPPINGS)
except Exception as exc:
    print(f"could not load the node registry: {exc}")
    sys.exit(0)

hits = sorted(n for n in names if "dancer" in n.lower())
audio = sorted(n for n in names if "audioencoder" in n.lower().replace("_", ""))

if hits:
    print("Wan-Dancer nodes found: " + ", ".join(hits))
else:
    print("NO node with 'Dancer' in its name is registered.")
    print("This ComfyUI build predates native Wan-Dancer support.")
    print("Re-run setup with WD_UPDATE_COMFYUI=1, or use a newer base image.")
if audio:
    print("audio encoder nodes: " + ", ".join(audio))
PYEOF
) || warn "node registry check could not run"

section "Summary"
if (( MISSING == 0 )); then
  ok "all required model files are in place"
else
  err "${MISSING} required model file(s) missing — run: bash ${WD_REPO_DIR}/setup.sh --models-only"
fi
df -h "${MODELS}" 2>/dev/null | tail -2 >&2

# Exit status reflects only the model files: a missing node registry is
# reported above but is not something this script can decide on.
(( MISSING == 0 ))
