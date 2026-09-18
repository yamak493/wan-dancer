#!/usr/bin/env python3
"""Manifest-driven model downloader for the Wan-Dancer RunPod template.

Reads config/models.tsv and places every listed file under
<models-root>/<dest_subdir>/<basename>.

Two properties matter for an unattended template:

* **Path drift tolerance.** Only the basename in the manifest has to be right.
  If the exact in-repo path is gone (upstream repos move files in and out of
  ``split_files/``), the real path is looked up through the HuggingFace API by
  basename before giving up.
* **Idempotency.** A file whose local size already matches the size reported by
  the API is left alone, so restarting a pod does not re-download ~45 GB.

Exit status is non-zero only when a *core* file could not be fetched.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    from huggingface_hub import HfApi, hf_hub_download
    from huggingface_hub.utils import GatedRepoError, RepositoryNotFoundError
except ImportError:  # pragma: no cover - surfaced by the caller
    sys.stderr.write(
        "huggingface_hub is not installed. Run: pip install 'huggingface_hub[hf_transfer]'\n"
    )
    raise SystemExit(2)

RETRIES = 4
BACKOFF_BASE = 2  # 2s, 4s, 8s, 16s


@dataclass
class Entry:
    group: str
    repo: str
    path: str
    dest_subdir: str

    @property
    def basename(self) -> str:
        return self.path.rsplit("/", 1)[-1]


def log(msg: str) -> None:
    sys.stderr.write(f"[download] {msg}\n")
    sys.stderr.flush()


def parse_manifest(manifest: Path, groups: set[str]) -> list[Entry]:
    entries: list[Entry] = []
    for lineno, raw in enumerate(manifest.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = [f.strip() for f in line.split("\t") if f.strip()]
        if len(fields) != 4:
            log(f"{manifest}:{lineno}: expected 4 tab-separated fields, got {len(fields)} — skipped")
            continue
        entry = Entry(*fields)
        if entry.group in groups:
            entries.append(entry)
    return entries


def apply_overrides(entries: list[Entry]) -> list[Entry]:
    """Swap the UMT5 text encoder for the fp16 build when asked."""
    if os.environ.get("WD_TEXT_ENCODER", "").lower() != "fp16":
        return entries
    out = []
    for e in entries:
        if e.dest_subdir == "text_encoders" and "umt5_xxl_fp8" in e.basename:
            log("WD_TEXT_ENCODER=fp16 — using umt5_xxl_fp16.safetensors")
            e = Entry(e.group, e.repo, "split_files/text_encoders/umt5_xxl_fp16.safetensors", e.dest_subdir)
        elif e.group == "optional" and "umt5_xxl_fp16" in e.basename:
            continue  # already covered by the swap above
        out.append(e)
    return out


def resolve(api: HfApi, entry: Entry, cache: dict[str, list[str]]) -> str | None:
    """Return the real in-repo path for ``entry``, or None if it is not there."""
    if entry.repo not in cache:
        try:
            cache[entry.repo] = api.list_repo_files(entry.repo)
        except (RepositoryNotFoundError, GatedRepoError) as exc:
            log(f"cannot list {entry.repo}: {type(exc).__name__}")
            cache[entry.repo] = []
        except Exception as exc:  # network hiccup — treat as unknown
            log(f"cannot list {entry.repo}: {exc}")
            cache[entry.repo] = []

    files = cache[entry.repo]
    if not files:
        # Listing failed; optimistically try the manifest path as-is.
        return entry.path
    if entry.path in files:
        return entry.path

    matches = [f for f in files if f.rsplit("/", 1)[-1] == entry.basename]
    if matches:
        matches.sort(key=len)
        log(f"{entry.repo}: '{entry.path}' not found, using '{matches[0]}'")
        return matches[0]

    log(f"{entry.repo}: no file named '{entry.basename}' in the repo")
    return None


_SIZE_CACHE: dict[str, dict[str, int | None]] = {}


def remote_size(api: HfApi, repo: str, path: str) -> int | None:
    """Size of ``path`` per the HF API, or None when unknown.

    Metadata for the whole repo is fetched once and cached: a per-file call
    would re-download the full file listing for every manifest entry.
    """
    if repo not in _SIZE_CACHE:
        try:
            info = api.model_info(repo, files_metadata=True)
            _SIZE_CACHE[repo] = {
                s.rfilename: s.size for s in (info.siblings or [])
            }
        except Exception as exc:
            log(f"could not read metadata for {repo}: {exc}")
            _SIZE_CACHE[repo] = {}
    return _SIZE_CACHE[repo].get(path)


def fetch(api: HfApi, entry: Entry, path: str, dest: Path) -> bool:
    target = dest / entry.basename
    expected = remote_size(api, entry.repo, path)

    if target.exists():
        actual = target.stat().st_size
        if expected is None or actual == expected:
            log(f"present, skipping: {target.name} ({actual / 2**30:.2f} GiB)")
            return True
        log(f"size mismatch for {target.name} ({actual} != {expected}) — re-downloading")

    dest.mkdir(parents=True, exist_ok=True)
    size_note = f" (~{expected / 2**30:.2f} GiB)" if expected else ""
    log(f"downloading {entry.repo}/{path}{size_note}")

    delay = BACKOFF_BASE
    for attempt in range(1, RETRIES + 1):
        try:
            got = hf_hub_download(
                repo_id=entry.repo,
                filename=path,
                local_dir=str(dest),
                token=os.environ.get("HF_TOKEN") or None,
            )
            got_path = Path(got)
            # local_dir keeps the repo's directory layout; flatten it so the
            # file lands where ComfyUI's loaders look for it.
            if got_path.resolve() != target.resolve():
                target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(got_path, target)
                _prune_empty(dest, got_path.parent)
            log(f"done: {target.name}")
            return True
        except (RepositoryNotFoundError, GatedRepoError) as exc:
            log(f"{entry.repo} is gated or missing ({type(exc).__name__}); set HF_TOKEN if it needs a licence")
            return False
        except Exception as exc:
            if attempt == RETRIES:
                log(f"giving up on {entry.basename} after {RETRIES} attempts: {exc}")
                return False
            log(f"attempt {attempt}/{RETRIES} failed ({exc}); retrying in {delay}s")
            time.sleep(delay)
            delay *= 2
    return False


def _prune_empty(stop_at: Path, start: Path) -> None:
    """Remove the empty repo-layout directories left behind by the flatten."""
    current = start
    stop = stop_at.resolve()
    while current.resolve() != stop and stop in current.resolve().parents:
        try:
            current.rmdir()
        except OSError:
            return
        current = current.parent


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--models-root", required=True, type=Path,
                    help="the ComfyUI models directory")
    ap.add_argument("--groups", default="core,speed",
                    help="comma separated manifest groups to download")
    args = ap.parse_args()

    groups = {g.strip() for g in args.groups.split(",") if g.strip()}
    entries = apply_overrides(parse_manifest(args.manifest, groups))
    if not entries:
        log("manifest selected no files — nothing to do")
        return 0

    log(f"{len(entries)} file(s) selected (groups: {', '.join(sorted(groups))})")
    api = HfApi(token=os.environ.get("HF_TOKEN") or None)
    listing_cache: dict[str, list[str]] = {}
    failed_core: list[str] = []
    failed_other: list[str] = []

    for entry in entries:
        path = resolve(api, entry, listing_cache)
        success = False
        if path is not None:
            success = fetch(api, entry, path, args.models_root / entry.dest_subdir)
        if not success:
            (failed_core if entry.group == "core" else failed_other).append(
                f"{entry.repo}/{entry.basename}"
            )

    if failed_other:
        log("non-core files that failed (generation still works without them):")
        for name in failed_other:
            log(f"  - {name}")
    if failed_core:
        log("CORE files that failed — Wan-Dancer will not run:")
        for name in failed_core:
            log(f"  - {name}")
        return 1

    log("all core models present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
