# Workflows

`scripts/06_workflows.sh` installs a Wan-Dancer workflow into
`ComfyUI/user/default/workflows/`, trying three sources in order:

1. the official template bundled with ComfyUI (`comfyui_workflow_templates`),
2. the same template fetched from `Comfy-Org/workflow_templates` on GitHub,
3. any `*.json` committed in **this** directory.

Nothing is committed here on purpose: the upstream template is kept in step
with the node signatures ComfyUI ships, and a stale hand-written copy would
break on the next node revision.

Drop your own JSON here to pin a workflow — once a file exists, it is used as
the step-3 fallback and travels with the template.
