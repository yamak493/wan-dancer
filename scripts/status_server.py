#!/usr/bin/env python3
"""Serves the setup progress page on the pod's exposed HTTP port.

Why this exists: ComfyUI only binds its port after every setup stage has
finished, so for the ~5-15 minutes the model download takes, the RunPod
"Connect" button leads nowhere and the log tab is the only channel. This holds
the port in the meantime and shows what the boot is doing, then gets out of
the way so ComfyUI can bind (see scripts/90_start.sh).

Deliberate constraints:

* **Stdlib only.** It starts before stage 1 installs anything.
* **No JavaScript.** A meta refresh cannot break, and there is no console to
  debug on a pod whose shell may not be reachable.
* **Never fatal.** If the port is already held (the image started ComfyUI
  itself, say), it reports that and exits 0 rather than failing the boot.

Routes: ``/status.json`` returns the raw document (which the tests assert
against), ``/log`` the plain-text tail, anything else the HTML page.
"""

from __future__ import annotations

import html
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wd_status  # noqa: E402

LOG_TAIL_LINES = 200
REFRESH_SECONDS = 5

STATE_MARK = {
    "done": ("✓", "ok"),
    "running": ("⟳", "run"),
    "failed": ("✕", "bad"),
    "skipped": ("–", "skip"),
    "pending": ("·", "idle"),
}


def human_bytes(value: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(value) < 1024 or unit == "TiB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{value:.0f} B"
        value /= 1024
    return f"{value:.1f} TiB"


def human_duration(seconds: float) -> str:
    seconds = int(max(seconds, 0))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60:02d}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60:02d}m"


def tail(path: Path, lines: int) -> str:
    """Last ``lines`` lines of ``path``, read from the end.

    Reads a bounded window rather than the whole file: ComfyUI keeps logging
    into the same file after handover, so this can grow well past the tail.
    """
    try:
        size = path.stat().st_size
        window = min(size, lines * 400)
        with open(path, "rb") as handle:
            handle.seek(size - window)
            data = handle.read()
    except OSError:
        return ""
    text = data.decode("utf-8", errors="replace")
    if window < size:
        text = text.split("\n", 1)[-1]  # drop the partial first line
    return "\n".join(text.splitlines()[-lines:])


def strip_ansi(text: str) -> str:
    out, i = [], 0
    while i < len(text):
        if text[i] == "\033":
            j = text.find("m", i)
            if j != -1 and j - i < 12:
                i = j + 1
                continue
        out.append(text[i])
        i += 1
    return "".join(out)


CSS = """
*{box-sizing:border-box}
:root{
  --bg:#f7f7f8; --panel:#fff; --fg:#1a1a1b; --muted:#6b6b70; --line:#e3e3e6;
  --ok:#1a7f4b; --run:#1f6feb; --bad:#c2321a; --idle:#9a9aa0; --skip:#9a9aa0;
  --bar:#1f6feb; --bar-bg:#e3e3e6;
}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
  --bg:#17181a; --panel:#1f2023; --fg:#ececed; --muted:#9a9aa0; --line:#2e3034;
  --ok:#3fb950; --run:#58a6ff; --bad:#f85149; --idle:#6b6b70; --skip:#6b6b70;
  --bar:#58a6ff; --bar-bg:#2e3034;
}}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);
  font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:820px;margin:0 auto}
h1{font-size:20px;margin:0 0 2px}
.sub{color:var(--muted);font-size:13px;margin-bottom:20px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
  padding:16px 18px;margin-bottom:16px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;
  color:var(--muted);margin:0 0 12px;font-weight:600}
.banner{border-left:3px solid var(--run);font-weight:500}
.banner.ok{border-left-color:var(--ok)} .banner.bad{border-left-color:var(--bad)}
ul{list-style:none;margin:0;padding:0}
li{display:flex;align-items:baseline;gap:10px;padding:5px 0}
.mark{width:1.1em;text-align:center;font-weight:700;flex:none}
.ok{color:var(--ok)} .run{color:var(--run)} .bad{color:var(--bad)}
.idle{color:var(--idle)} .skip{color:var(--skip)}
.name{flex:1;min-width:0;overflow-wrap:anywhere}
.meta{color:var(--muted);font-size:13px;flex:none;
  font-variant-numeric:tabular-nums}
.barwrap{height:8px;background:var(--bar-bg);border-radius:99px;overflow:hidden;
  margin:4px 0 10px}
.bar{height:100%;background:var(--bar);border-radius:99px;transition:width .4s}
.big{font-size:22px;font-variant-numeric:tabular-nums;margin-bottom:2px}
pre{margin:0;padding:12px;background:var(--bg);border:1px solid var(--line);
  border-radius:8px;overflow-x:auto;font-size:12px;line-height:1.5;
  max-height:22em;overflow-y:auto;white-space:pre-wrap;overflow-wrap:anywhere}
a{color:var(--run)}
"""


def render(status: dict, log_path: Path, port: int) -> str:
    verdict = status.get("verdict", "running")
    phase = status.get("phase", "setup")

    if verdict == "ready":
        tone, headline = "ok", "Ready — ComfyUI is starting"
        detail = "This page hands the port over to ComfyUI. Reload in a few seconds."
    elif verdict in ("missing", "failed"):
        tone, headline = "bad", "Setup finished with problems"
        detail = str(status.get("message") or "See the log below.")
    else:
        tone, headline = "run", "Setting up…"
        detail = "Models are downloading. ComfyUI starts automatically when this finishes."

    parts = [
        "<!doctype html><html lang=en><head><meta charset=utf-8>",
        "<meta name=viewport content='width=device-width,initial-scale=1'>",
        f"<meta http-equiv=refresh content={REFRESH_SECONDS}>",
        "<title>Wan-Dancer setup</title>",
        f"<style>{CSS}</style></head><body><div class=wrap>",
        "<h1>Wan-Dancer setup</h1>",
    ]

    elapsed = ""
    if status.get("started_at") and status.get("updated_at"):
        elapsed = f" · elapsed {human_duration(status['updated_at'] - status['started_at'])}"
    parts.append(f"<div class=sub>port {port} · phase {html.escape(phase)}{elapsed}</div>")

    parts.append(
        f"<div class='card banner {tone}'>{html.escape(headline)}"
        f"<div class=sub style='margin:4px 0 0'>{html.escape(detail)}</div></div>"
    )

    # ---- stages ----
    stages = status.get("stages") or {}
    if stages:
        parts.append("<div class=card><h2>Stages</h2><ul>")
        for key, stage in sorted(stages.items(), key=lambda kv: kv[1].get("order", 0)):
            mark, cls = STATE_MARK.get(stage.get("state", "pending"), STATE_MARK["pending"])
            took = ""
            if stage.get("t0"):
                end = stage.get("t1") or status.get("updated_at") or stage["t0"]
                took = human_duration(end - stage["t0"])
            parts.append(
                f"<li><span class='mark {cls}'>{mark}</span>"
                f"<span class=name>{html.escape(str(stage.get('label', key)))}</span>"
                f"<span class=meta>{took}</span></li>"
            )
        parts.append("</ul></div>")

    # ---- download ----
    dl = status.get("download") or {}
    total, done = dl.get("total_bytes") or 0, dl.get("done_bytes") or 0
    if total or dl.get("files"):
        pct = (done / total * 100) if total else 0
        parts.append("<div class=card><h2>Model download</h2>")
        parts.append(f"<div class=big>{pct:.0f}%</div>")
        parts.append(
            f"<div class=sub>{human_bytes(done)} of {human_bytes(total)}"
            + (f" · {human_bytes(dl['rate_bps'])}/s" if dl.get("rate_bps") else "")
            + (f" · ~{human_duration(dl['eta_s'])} left" if dl.get("eta_s") else "")
            + "</div>"
        )
        parts.append(f"<div class=barwrap><div class=bar style='width:{min(pct,100):.1f}%'></div></div>")

        files = dl.get("files") or {}
        if files:
            parts.append("<ul>")
            for name, info in sorted(files.items()):
                mark, cls = STATE_MARK.get(info.get("state", "pending"), STATE_MARK["pending"])
                size = human_bytes(info["size"]) if info.get("size") else ""
                parts.append(
                    f"<li><span class='mark {cls}'>{mark}</span>"
                    f"<span class=name>{html.escape(name)}</span>"
                    f"<span class=meta>{size}</span></li>"
                )
            parts.append("</ul>")
        parts.append("</div>")

    # ---- readiness ----
    rows = (status.get("readiness") or {}).get("rows") or []
    if rows:
        parts.append("<div class=card><h2>Readiness</h2><ul>")
        for row in rows:
            mark, cls = ("✓", "ok") if row.get("ok") else ("✕", "bad")
            parts.append(
                f"<li><span class='mark {cls}'>{mark}</span>"
                f"<span class=name>{html.escape(str(row.get('label', '')))}</span>"
                f"<span class=meta>{html.escape(str(row.get('detail', '')))}</span></li>"
            )
        parts.append("</ul></div>")

    # ---- log ----
    text = tail(log_path, LOG_TAIL_LINES)
    parts.append("<div class=card><h2>Log "
                 f"(last {LOG_TAIL_LINES} lines · <a href=/log>raw</a>)</h2>")
    parts.append(f"<pre>{html.escape(strip_ansi(text)) if text else 'No log yet.'}</pre></div>")

    parts.append("</div></body></html>")
    return "".join(parts)


def make_handler(status_path: Path, log_path: Path, port: int):
    class Handler(BaseHTTPRequestHandler):
        server_version = "wan-dancer-status"

        def _send(self, body: bytes, content_type: str) -> None:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            route = self.path.split("?", 1)[0].rstrip("/") or "/"
            try:
                if route == "/status.json":
                    import json
                    self._send(json.dumps(wd_status.read(status_path)).encode(),
                               "application/json; charset=utf-8")
                elif route == "/log":
                    self._send(strip_ansi(tail(log_path, 2000)).encode(),
                               "text/plain; charset=utf-8")
                else:
                    self._send(render(wd_status.read(status_path), log_path, port).encode(),
                               "text/html; charset=utf-8")
            except BrokenPipeError:
                pass  # the browser navigated away mid-write

        do_HEAD = do_GET

        def log_message(self, *_args) -> None:
            pass  # every meta-refresh would otherwise spam the boot log

    return Handler


def main() -> int:
    port = int(os.environ.get("WD_COMFY_PORT", "8188"))
    host = os.environ.get("WD_STATUS_HOST", "0.0.0.0")
    status_path = Path(os.environ.get("WD_STATUS_DIR", "/tmp/wan-dancer")) / "status.json"
    log_path = Path(os.environ.get("WD_LOG_FILE", "/var/log/wan-dancer/setup.log"))

    try:
        server = ThreadingHTTPServer((host, port), make_handler(status_path, log_path, port))
    except OSError as exc:
        # Almost always "address already in use" — something else holds the
        # port. Not our problem to solve, and not a reason to fail the boot.
        sys.stderr.write(f"[status] not starting progress page on {host}:{port}: {exc}\n")
        return 0

    server.daemon_threads = True
    sys.stderr.write(f"[status] progress page on http://{host}:{port}\n")
    sys.stderr.flush()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # never take the boot down with us
        sys.stderr.write(f"[status] progress page crashed: {exc}\n")
        raise SystemExit(0)
