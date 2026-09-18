#!/usr/bin/env bash
#
# Wan-Dancer on RunPod — one-shot bootstrap.
#
# Invoked by the RunPod template's "Container start command":
#
#   bash -c "git clone https://github.com/yamak493/wan-dancer.git /tmp/setup && bash /tmp/setup/setup.sh"
#
# Runs six idempotent stages and then execs ComfyUI in the foreground. Safe to
# re-run: completed stages are skipped and present models are not re-downloaded.
#
# Flags:
#   --models-only   re-run just the model download, then exit
#   --no-start      run setup but do not launch ComfyUI
#   --force         ignore state markers and redo every stage
#   --no-status     do not serve the progress page on the ComfyUI port
#
set -euo pipefail

WD_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WD_REPO_DIR

source "${WD_REPO_DIR}/scripts/lib.sh"
source "${WD_REPO_DIR}/scripts/paths.sh"

MODELS_ONLY=0
START_COMFY=1
for arg in "$@"; do
  case "$arg" in
    --models-only) MODELS_ONLY=1; START_COMFY=0 ;;
    --no-start)    START_COMFY=0 ;;
    --force)       export WD_FORCE=1 ;;
    --no-status)   export WD_STATUS_PAGE=0 ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             warn "unknown argument ignored: ${arg}" ;;
  esac
done

# An .env next to this script (or on the persistent volume) can hold HF_TOKEN
# and any WD_* override without baking it into the RunPod template.
for envfile in "${WD_REPO_DIR}/.env" "${WD_PERSIST_ROOT:-/workspace}/wan-dancer/.env"; do
  if [[ -f "$envfile" ]]; then
    log "loading environment from ${envfile}"
    set -a; source "$envfile"; set +a
  fi
done

# ------------------------------------------------------- logging to a file ----
# RunPod's log pane has a finite buffer and loses everything on a pod restart,
# so mirror the whole boot to a file as well. The path is fixed rather than
# derived from WD_STATE_DIR because that is not resolved until further down,
# and this has to cover the early failures too.
#
# Interactive invocations already have a terminal, so only the boot path tees.
export WD_LOG_FILE="${WD_LOG_FILE:-/var/log/wan-dancer/setup.log}"
export WD_STATUS_DIR="${WD_STATUS_DIR:-/tmp/wan-dancer}"

if (( START_COMFY )) && [[ "${WD_STATUS_PAGE:-1}" != "0" ]]; then
  if mkdir -p "$(dirname "${WD_LOG_FILE}")" 2>/dev/null; then
    # The redirection survives the exec into ComfyUI at the end, so its output
    # lands in the same file — which is what you want when diagnosing a boot.
    exec > >(tee -a "${WD_LOG_FILE}") 2>&1
  else
    WD_LOG_FILE=""
  fi
fi

# ------------------------------------------------------------ progress page ----
# ComfyUI only binds its port once every stage below has finished, which would
# otherwise leave the pod's exposed port dead for the whole download. Hold it
# with a progress page until 90_start.sh hands it over.
STATUS_PID=""
stop_status_server() {
  [[ -n "${STATUS_PID}" ]] || return 0
  kill "${STATUS_PID}" 2>/dev/null || true
  wait "${STATUS_PID}" 2>/dev/null || true
  STATUS_PID=""
}
# Without this a crashed setup leaves the page holding the port, and the next
# thing to try binding it fails.
trap stop_status_server EXIT INT TERM

if (( START_COMFY )) && [[ "${WD_STATUS_PAGE:-1}" != "0" ]]; then
  status_init
  status_set port "${WD_COMFY_PORT:-8188}"
  python3 "${WD_REPO_DIR}/scripts/status_server.py" &
  STATUS_PID=$!
  echo "${STATUS_PID}" > "${WD_STATUS_DIR}/server.pid" 2>/dev/null || true
fi

section "Wan-Dancer RunPod bootstrap"
log "repo:     ${WD_REPO_DIR}"
log "revision: $(git -C "${WD_REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
log "host:     $(uname -sr)"
[[ -n "${WD_LOG_FILE}" ]] && log "log file: ${WD_LOG_FILE}"
[[ -n "${STATUS_PID}" ]] && log "progress: http port ${WD_COMFY_PORT:-8188} until ComfyUI takes over"

# ------------------------------------------------------------------ paths ----
COMFY_DIR="$(detect_comfy_dir)" || die "could not find ComfyUI (no main.py in the usual locations).
This template expects a ComfyUI base image such as runpod/comfyui.
Set COMFY_DIR=/path/to/ComfyUI to point it at a custom install."
export COMFY_DIR

export WD_PERSIST_ROOT="${WD_PERSIST_ROOT:-/workspace}"
if WD_MODEL_ROOT="$(resolve_model_root)"; then
  WD_MODELS_PERSISTENT=1
else
  WD_MODELS_PERSISTENT=0
fi
export WD_MODEL_ROOT WD_MODELS_PERSISTENT

# State markers live next to the models so a persistent volume remembers what
# was already set up; on ephemeral disk they simply reset with the container.
if [[ "${WD_MODELS_PERSISTENT}" == "1" ]]; then
  export WD_STATE_DIR="${WD_PERSIST_ROOT}/wan-dancer/.state"
else
  export WD_STATE_DIR="${WD_MODEL_ROOT%/models}/.state"
fi
mkdir -p "${WD_STATE_DIR}"

# ------------------------------------------------------------------ stages ----
run_stage() {
  local script="${WD_REPO_DIR}/scripts/$1"
  local key="${1%.sh}"          # 01_system_deps.sh -> 01_system_deps
  [[ -f "$script" ]] || die "missing stage script: ${script}"

  status_stage "$key" running
  if bash "$script"; then
    status_stage "$key" done
    return 0
  fi
  status_stage "$key" failed
  return 1
}

if (( MODELS_ONLY )); then
  run_stage 02_storage.sh
  run_stage 05_models.sh
  ok "model refresh complete"
  exit 0
fi

run_stage 01_system_deps.sh
run_stage 02_storage.sh
run_stage 03_comfyui.sh
run_stage 04_custom_nodes.sh

MODELS_OK=1
run_stage 05_models.sh || MODELS_OK=0

run_stage 06_workflows.sh

# The readiness check is authoritative: it looks at what is actually on disk.
bash "${WD_REPO_DIR}/scripts/healthcheck.sh" || MODELS_OK=0

section "Setup finished"
if (( MODELS_OK )); then
  status_set verdict ready
  status_set message "ComfyUI is starting"
  ok "Wan-Dancer is ready — open the pod's HTTP port ${WD_COMFY_PORT:-8188}"
else
  status_set verdict missing
  status_set message "Core models are missing — re-run: setup.sh --models-only"
  warn "setup finished with MISSING MODELS — see stage 5 above."
  warn "ComfyUI still starts so you can retry from a terminal:"
  warn "  bash ${WD_REPO_DIR}/setup.sh --models-only"
fi

if (( START_COMFY )); then
  # Release the port before ComfyUI tries to bind it, and drop the trap so the
  # exec'd process does not inherit a handler for a PID that is already gone.
  status_set phase starting
  stop_status_server
  trap - EXIT INT TERM

  # exec, not call: this process must stay in the foreground for the pod to
  # keep running.
  exec bash "${WD_REPO_DIR}/scripts/90_start.sh"
fi

log "--no-start given; not launching ComfyUI"
