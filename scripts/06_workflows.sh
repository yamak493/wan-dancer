#!/usr/bin/env bash
# Stage 6 — put a ready-to-run Wan-Dancer workflow in ComfyUI's workflow
# browser so the pod is genuinely "open the UI and hit Run".
set -euo pipefail
source "${WD_REPO_DIR}/scripts/lib.sh"

section "Stage 6/6 — workflows"

DEST="${COMFY_DIR}/user/default/workflows"
mkdir -p "$DEST"

installed=0

# 1) Preferred: the official template that ships with ComfyUI itself. Newer
#    ComfyUI installs it as the comfyui_workflow_templates package, which is
#    exactly what the "Browse Templates" dialog reads.
PY="$(python_bin)"
TPL_DIR="$("$PY" - <<'PYEOF' 2>/dev/null || true
import pathlib
try:
    import comfyui_workflow_templates as m
    print(pathlib.Path(m.__file__).parent / "templates")
except Exception:
    pass
PYEOF
)"

if [[ -n "${TPL_DIR}" && -d "${TPL_DIR}" ]]; then
  while IFS= read -r tpl; do
    cp -f "$tpl" "${DEST}/$(basename "$tpl")"
    log "installed bundled template: $(basename "$tpl")"
    installed=$(( installed + 1 ))
  done < <(find "$TPL_DIR" -maxdepth 1 -iname '*dancer*.json' 2>/dev/null)
fi

# 2) Otherwise pull it from the public template repo. Listed through the API so
#    a renamed template still gets found.
if (( installed == 0 )) && [[ "${WD_FETCH_WORKFLOWS:-1}" == "1" ]]; then
  log "no bundled Wan-Dancer template; trying Comfy-Org/workflow_templates"
  API="https://api.github.com/repos/Comfy-Org/workflow_templates/contents/templates"
  LISTING="$(curl -fsSL --max-time 30 "$API" 2>/dev/null || true)"
  if [[ -n "$LISTING" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      url="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/${name}"
      if retry 3 curl -fsSL --max-time 120 -o "${DEST}/${name}" "$url"; then
        log "fetched template: ${name}"
        installed=$(( installed + 1 ))
      else
        warn "could not fetch ${name}"
      fi
    done < <(echo "$LISTING" | grep -oE '"name": *"[^"]*dancer[^"]*\.json"' \
               | sed -E 's/.*" *: *"//; s/"$//' | sort -u)
  else
    warn "template listing unavailable (offline or rate-limited)"
  fi
fi

# 3) Last resort: the API-format workflow committed in this repo. Not as pretty
#    in the editor as the official template, but it runs.
if (( installed == 0 )); then
  if compgen -G "${WD_REPO_DIR}/workflows/*.json" >/dev/null; then
    cp -f "${WD_REPO_DIR}"/workflows/*.json "${DEST}/"
    log "installed fallback workflow(s) from this repo"
    installed=$(( installed + 1 ))
  fi
fi

if (( installed > 0 )); then
  ok "workflows available in ComfyUI -> Workflows sidebar (${installed} file(s))"
else
  warn "no Wan-Dancer workflow installed — use Browse Templates in the UI,"
  warn "or drop your own JSON into ${DEST}"
fi

# Sample assets: Wan-Dancer needs one reference image plus one audio track.
mkdir -p "${COMFY_DIR}/input"
cat > "${COMFY_DIR}/input/README-wan-dancer.txt" <<'TXT'
Wan-Dancer inputs
=================
Put your own files in this folder; they then show up in the LoadImage /
LoadAudio node dropdowns in ComfyUI.

  reference.png / .jpg   a single full-body shot of the character.
                         Full body in frame beats a head-and-shoulders crop —
                         the model can only animate limbs it can see.
  music.wav / .mp3       the track to dance to. Clear, steady beat works best.
                         Trim it first: generation cost scales with duration.
TXT

ok "stage 6 complete"
