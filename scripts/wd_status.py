#!/usr/bin/env python3
"""Shared status file used to drive the setup progress page.

One JSON file is the single source of truth for "what is the boot doing".
Bash stages poke it through the CLI at the bottom; ``download.py`` imports
:func:`update` directly from its monitor thread.

Two properties the readers depend on:

* **Atomic.** Every write goes to a temp file in the same directory and is
  ``os.replace``d into place, so the HTTP server (and the tests) never observe
  a half-written file and never need to retry a parse.
* **Merging.** Writers only ever describe their own corner of the document.
  Dicts merge recursively, so a stage transition cannot clobber the download
  numbers written moments earlier by another process.

Stdlib only, deliberately: this runs before stage 1 installs anything.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path

try:
    import fcntl
except ImportError:  # non-POSIX; the lock is an optimisation, not a necessity
    fcntl = None  # type: ignore[assignment]

# The six stages, in the order setup.sh runs them, with the labels the page
# shows. Seeded up front so the page can display the whole plan immediately
# rather than growing a row at a time.
STAGES: list[tuple[str, str]] = [
    ("01_system_deps", "System dependencies"),
    ("02_storage", "Storage layout"),
    ("03_comfyui", "ComfyUI"),
    ("04_custom_nodes", "Custom nodes"),
    ("05_models", "Model download"),
    ("06_workflows", "Workflows"),
]


def _now() -> float:
    return time.time()


def _merge(base: dict, patch: dict) -> dict:
    """Recursively merge ``patch`` into ``base``. Lists and scalars replace."""
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            _merge(base[key], value)
        else:
            base[key] = value
    return base


def _read(path: Path) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def update(path: str | os.PathLike[str], patch: dict) -> dict:
    """Merge ``patch`` into the status file and return the new document."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)

    lock = None
    if fcntl is not None:
        # A separate lock file: locking the status file itself would race with
        # the os.replace that swaps its inode out from under us.
        lock = open(str(target) + ".lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        doc = _read(target)
        doc.setdefault("started_at", _now())
        _merge(doc, patch)
        doc["updated_at"] = _now()

        fd, tmp = tempfile.mkstemp(dir=str(target.parent), prefix=".status-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(doc, handle, indent=1, sort_keys=True)
            os.replace(tmp, target)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return doc
    finally:
        if lock is not None:
            fcntl.flock(lock, fcntl.LOCK_UN)
            lock.close()


def read(path: str | os.PathLike[str]) -> dict:
    """Read the status file, tolerating absence and corruption."""
    return _read(Path(path))


# ------------------------------------------------------------------- CLI ----
def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write(
            "usage: wd_status.py <file> init|stage|set|append ...\n"
            "  init                         seed the stage list\n"
            "  stage <key> <state>          running|done|failed|skipped\n"
            "  set <dotted.key> <value>     value is parsed as JSON, else a string\n"
            "  append <dotted.key> <value>  push onto a list\n"
        )
        return 2

    path, action, args = argv[1], argv[2], argv[3:]

    if action == "init":
        update(path, {
            "phase": "setup",
            "verdict": "running",
            "started_at": _now(),
            "stages": {
                key: {"label": label, "state": "pending", "order": i}
                for i, (key, label) in enumerate(STAGES)
            },
        })
        return 0

    if action == "stage":
        if len(args) != 2:
            sys.stderr.write("stage needs <key> <state>\n")
            return 2
        key, state = args
        patch: dict = {"state": state}
        if state == "running":
            patch["t0"] = _now()
        else:
            patch["t1"] = _now()
        update(path, {"stages": {key: patch}})
        return 0

    if action in ("set", "append"):
        if len(args) != 2:
            sys.stderr.write(f"{action} needs <dotted.key> <value>\n")
            return 2
        dotted, raw = args
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            value = raw  # a bare string is the common case from bash

        if action == "append":
            doc = read(path)
            cursor: object = doc
            for part in dotted.split("."):
                if not isinstance(cursor, dict):
                    cursor = None
                    break
                cursor = cursor.get(part)
            existing = cursor if isinstance(cursor, list) else []
            value = existing + [value]

        patch = value
        for part in reversed(dotted.split(".")):
            patch = {part: patch}
        update(path, patch)
        return 0

    sys.stderr.write(f"unknown action: {action}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
