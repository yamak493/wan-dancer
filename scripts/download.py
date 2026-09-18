#!/usr/bin/env python3
"""Manifest-driven, parallel model downloader for the Wan-Dancer RunPod template.

This pod is built to be thrown away: models are fetched fresh on every boot
rather than parked on a volume, so cold-start throughput is the whole game.
Two layers of parallelism are stacked to get there:

1. **Within a file** — HuggingFace's own chunked, multi-connection backend.
   Which one that is depends on the installed ``huggingface_hub``:
   1.x downloads through Xet, while 0.x uses ``hf_transfer``. The right one is
   enabled in :func:`tune_backend`, which must run *before* the library is
   imported because both flags are read into module constants at import time.
2. **Across files** — a thread pool, so the two ~16 GB experts and the smaller
   encoders are in flight together instead of queued behind each other.

Per-file progress bars are suppressed when downloading concurrently (they
interleave into noise in a pod log) and replaced by one aggregate
progress/throughput line, which is what you actually want when watching a
cold boot.

Path drift is tolerated: only the basename in the manifest has to be correct,
because the real in-repo path is looked up through the API when the manifest
path is gone. Files already on disk at the right size are skipped, so a re-run
costs nothing.

Exit status is non-zero only when a *core* file could not be fetched.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from importlib.metadata import PackageNotFoundError, version as pkg_version
from pathlib import Path

RETRIES = 4
BACKOFF_BASE = 2  # 2s, 4s, 8s, 16s
DEFAULT_CONCURRENCY = 4
PROGRESS_INTERVAL = 15  # seconds between aggregate progress lines

_print_lock = threading.Lock()


def log(msg: str) -> None:
    with _print_lock:
        sys.stderr.write(f"[download] {msg}\n")
        sys.stderr.flush()


# --------------------------------------------------------------- backend ----
def tune_backend(concurrency: int) -> str:
    """Enable the fastest available transfer backend.

    Returns a human-readable description of what got switched on. Must be
    called before ``huggingface_hub`` is imported.
    """
    try:
        hub_version = pkg_version("huggingface_hub")
    except PackageNotFoundError:
        return "huggingface_hub not installed"

    try:
        major = int(hub_version.split(".")[0])
    except ValueError:
        major = 0

    notes = [f"huggingface_hub {hub_version}"]

    if major >= 1:
        # 1.x: Xet is the chunked/parallel backend. High-performance mode
        # raises its concurrency and buffer sizes.
        os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")
        try:
            import hf_xet  # noqa: F401
            notes.append("Xet high-performance mode")
        except ImportError:
            notes.append("Xet NOT installed (pip install hf_xet) — falling back to plain HTTPS")
        if os.environ.pop("HF_HUB_ENABLE_HF_TRANSFER", None):
            notes.append("ignored HF_HUB_ENABLE_HF_TRANSFER (no longer used in 1.x)")
    else:
        # 0.x: hf_transfer is the Rust multi-connection downloader.
        try:
            import hf_transfer  # noqa: F401
            os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")
            notes.append("hf_transfer enabled")
        except ImportError:
            notes.append("hf_transfer NOT installed (pip install hf_transfer) — falling back to plain HTTPS")

    if concurrency > 1:
        # Interleaved per-file bars are unreadable; the monitor thread reports
        # aggregate progress instead.
        os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

    return "; ".join(notes)


# ------------------------------------------------------------- data model ----
@dataclass
class Entry:
    group: str
    repo: str
    path: str
    dest_subdir: str

    @property
    def basename(self) -> str:
        return self.path.rsplit("/", 1)[-1]


@dataclass
class Task:
    entry: Entry
    resolved_path: str
    expected_size: int | None
    dest: Path
    skip: bool = False
    ok: bool = False
    error: str = ""
    bytes_done: int = field(default=0)

    @property
    def target(self) -> Path:
        return self.dest / self.entry.basename


# ---------------------------------------------------------------- parsing ----
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


# --------------------------------------------------------------- planning ----
def build_plan(api, entries: list[Entry], models_root: Path) -> list[Task]:
    """Resolve paths and sizes up front, serially.

    Doing this before any transfer starts means the thread pool never touches
    the metadata caches, so no locking is needed around them, and it is cheap:
    one listing plus one metadata call per *repo*, not per file.
    """
    from huggingface_hub.utils import GatedRepoError, RepositoryNotFoundError

    listings: dict[str, list[str]] = {}
    sizes: dict[str, dict[str, int | None]] = {}

    def listing(repo: str) -> list[str]:
        if repo not in listings:
            try:
                listings[repo] = api.list_repo_files(repo)
            except (RepositoryNotFoundError, GatedRepoError) as exc:
                log(f"cannot list {repo}: {type(exc).__name__} "
                    f"(set HF_TOKEN if the repo needs a licence accepted)")
                listings[repo] = []
            except Exception as exc:
                log(f"cannot list {repo}: {exc}")
                listings[repo] = []
        return listings[repo]

    def size_of(repo: str, path: str) -> int | None:
        if repo not in sizes:
            try:
                info = api.model_info(repo, files_metadata=True)
                sizes[repo] = {s.rfilename: s.size for s in (info.siblings or [])}
            except Exception as exc:
                log(f"could not read metadata for {repo}: {exc}")
                sizes[repo] = {}
        return sizes[repo].get(path)

    tasks: list[Task] = []
    for entry in entries:
        files = listing(entry.repo)
        resolved: str | None = entry.path
        if files and entry.path not in files:
            matches = sorted((f for f in files if f.rsplit("/", 1)[-1] == entry.basename), key=len)
            if matches:
                log(f"{entry.repo}: '{entry.path}' not found, using '{matches[0]}'")
                resolved = matches[0]
            else:
                log(f"{entry.repo}: no file named '{entry.basename}' in the repo")
                resolved = None

        dest = models_root / entry.dest_subdir
        if resolved is None:
            tasks.append(Task(entry, "", None, dest, error="not present in the repo"))
            continue

        expected = size_of(entry.repo, resolved)
        task = Task(entry, resolved, expected, dest)

        if task.target.exists():
            actual = task.target.stat().st_size
            if expected is None or actual == expected:
                task.skip = True
                task.ok = True
                log(f"present, skipping: {task.target.name} ({actual / 2**30:.2f} GiB)")
            else:
                log(f"size mismatch for {task.target.name} ({actual} != {expected}) — re-downloading")
        tasks.append(task)

    return tasks


# -------------------------------------------------------------- transfers ----
def _is_permanent(exc: BaseException) -> str | None:
    """Describe ``exc`` when retrying it cannot possibly help.

    A missing file or a rejected token fails the same way every time, so the
    backoff loop would only add half a minute per file before reporting the
    same thing.
    """
    from huggingface_hub.utils import (
        EntryNotFoundError,
        GatedRepoError,
        RepositoryNotFoundError,
        RevisionNotFoundError,
    )

    if isinstance(exc, GatedRepoError):
        return "repo is gated — accept its licence and set HF_TOKEN"
    if isinstance(exc, RepositoryNotFoundError):
        return "repo not found, or private and HF_TOKEN is missing/unauthorised"
    if isinstance(exc, EntryNotFoundError):
        return "file not found in the repo (check the name in config/models.tsv)"
    if isinstance(exc, RevisionNotFoundError):
        return "revision not found in the repo"

    status = getattr(getattr(exc, "response", None), "status_code", None)
    if status in (401, 403):
        return f"HTTP {status} — HF_TOKEN missing or not authorised for this repo"
    if status == 404:
        return "HTTP 404 — file or repo is gone (check config/models.tsv)"
    return None


def fetch(task: Task) -> None:
    from huggingface_hub import hf_hub_download

    entry = task.entry
    task.dest.mkdir(parents=True, exist_ok=True)
    size_note = f" (~{task.expected_size / 2**30:.2f} GiB)" if task.expected_size else ""
    log(f"start  {entry.basename}{size_note}")
    started = time.monotonic()

    delay = BACKOFF_BASE
    for attempt in range(1, RETRIES + 1):
        try:
            got = Path(hf_hub_download(
                repo_id=entry.repo,
                filename=task.resolved_path,
                local_dir=str(task.dest),
                token=os.environ.get("HF_TOKEN") or None,
            ))
            # local_dir reproduces the repo's directory layout; flatten it so
            # the file lands where ComfyUI's loaders look for it.
            if got.resolve() != task.target.resolve():
                os.replace(got, task.target)
                _prune_empty(task.dest, got.parent)

            elapsed = max(time.monotonic() - started, 1e-6)
            task.bytes_done = task.target.stat().st_size
            rate = task.bytes_done / elapsed / 2**20
            log(f"done   {entry.basename} "
                f"({task.bytes_done / 2**30:.2f} GiB in {elapsed:.0f}s, {rate:.0f} MiB/s)")
            task.ok = True
            return
        except Exception as exc:
            permanent = _is_permanent(exc)
            if permanent is not None:
                task.error = permanent
                log(f"failed {entry.basename}: {permanent}")
                return
            if attempt == RETRIES:
                task.error = str(exc)
                log(f"failed {entry.basename} after {RETRIES} attempts: {exc}")
                return
            log(f"retry  {entry.basename}: attempt {attempt}/{RETRIES} failed ({exc}); waiting {delay}s")
            time.sleep(delay)
            delay *= 2


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


def _tree_bytes(root: Path) -> int:
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=True):
        for name in filenames:
            try:
                total += os.path.getsize(os.path.join(dirpath, name))
            except OSError:
                pass
    return total


def monitor(root: Path, baseline: int, total_expected: int, stop: threading.Event) -> None:
    """Report aggregate progress while the pool works.

    Measured by walking the destination tree, which counts the partial files
    the backends write in place — so this reflects real bytes on disk rather
    than completed-file milestones.
    """
    started = time.monotonic()
    while not stop.wait(PROGRESS_INTERVAL):
        done = max(_tree_bytes(root) - baseline, 0)
        elapsed = max(time.monotonic() - started, 1e-6)
        rate = done / elapsed
        msg = (f"progress {done / 2**30:.1f} GiB of ~{total_expected / 2**30:.1f} GiB "
               f"({rate / 2**20:.0f} MiB/s avg")
        if rate > 0 and total_expected > done:
            eta = (total_expected - done) / rate
            msg += f", ~{eta / 60:.0f} min left"
        log(msg + ")")


# ------------------------------------------------------------------- main ----
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--models-root", required=True, type=Path,
                    help="the ComfyUI models directory")
    ap.add_argument("--groups", default="core,speed",
                    help="comma separated manifest groups to download")
    ap.add_argument("--concurrency", type=int,
                    default=int(os.environ.get("WD_DOWNLOAD_CONCURRENCY", DEFAULT_CONCURRENCY)),
                    help="how many files to transfer at once")
    args = ap.parse_args()

    groups = {g.strip() for g in args.groups.split(",") if g.strip()}
    entries = apply_overrides(parse_manifest(args.manifest, groups))
    if not entries:
        log("manifest selected no files — nothing to do")
        return 0

    concurrency = max(1, min(args.concurrency, len(entries)))
    # Enable the fast backend *before* huggingface_hub is imported.
    backend = tune_backend(concurrency)
    log(f"transfer backend: {backend}")
    log(f"{len(entries)} file(s) selected (groups: {', '.join(sorted(groups))}); "
        f"{concurrency} concurrent transfer(s)")

    try:
        from huggingface_hub import HfApi
    except ImportError:
        log("huggingface_hub is not installed. Run: pip install 'huggingface_hub[hf_xet]'")
        return 2

    api = HfApi(token=os.environ.get("HF_TOKEN") or None)
    log("resolving files and sizes")
    tasks = build_plan(api, entries, args.models_root)

    pending = [t for t in tasks if not t.skip and not t.error]
    total_expected = sum(t.expected_size or 0 for t in pending)

    if pending:
        args.models_root.mkdir(parents=True, exist_ok=True)
        baseline = _tree_bytes(args.models_root)
        log(f"downloading {len(pending)} file(s), ~{total_expected / 2**30:.1f} GiB total")

        stop = threading.Event()
        mon = threading.Thread(target=monitor,
                               args=(args.models_root, baseline, total_expected, stop),
                               daemon=True)
        mon.start()
        wall_start = time.monotonic()

        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            futures = {pool.submit(fetch, t): t for t in pending}
            for future in as_completed(futures):
                exc = future.exception()
                if exc is not None:  # fetch() is defensive, so this is a bug
                    task = futures[future]
                    task.error = f"unexpected error: {exc}"
                    log(f"failed {task.entry.basename}: {task.error}")

        stop.set()
        wall = time.monotonic() - wall_start
        moved = sum(t.bytes_done for t in pending)
        log(f"transferred {moved / 2**30:.2f} GiB in {wall / 60:.1f} min "
            f"({moved / max(wall, 1e-6) / 2**20:.0f} MiB/s aggregate)")
    else:
        log("every selected file is already present")

    failed_core = [t for t in tasks if not t.ok and t.entry.group == "core"]
    failed_other = [t for t in tasks if not t.ok and t.entry.group != "core"]

    if failed_other:
        log("non-core files that failed (generation still works without them):")
        for t in failed_other:
            log(f"  - {t.entry.repo}/{t.entry.basename}: {t.error or 'unknown error'}")
    if failed_core:
        log("CORE files that failed — Wan-Dancer will not run:")
        for t in failed_core:
            log(f"  - {t.entry.repo}/{t.entry.basename}: {t.error or 'unknown error'}")
        return 1

    log("all core models present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
