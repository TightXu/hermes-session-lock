"""Round-trip test for the session-lock backend half against a throwaway HERMES_HOME.

No server, no real registry: the test writes three fake leases, points HERMES_HOME at a temp
directory, and calls the router functions directly.

    <hermes home>/.venv/Scripts/python.exe tests/test_release.py     # Windows
    python tests/test_release.py                                     # POSIX

The hermes-agent source tree must be importable. Resolution order:
    $HERMES_REPO, $HERMES_HOME/hermes-agent, ~/.hermes/hermes-agent,
    %LOCALAPPDATA%/hermes/hermes-agent
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGIN_DIR = REPO_ROOT / "dashboard"


def find_hermes_repo() -> Path:
    candidates = []
    if os.environ.get("HERMES_REPO"):
        candidates.append(Path(os.environ["HERMES_REPO"]))
    if os.environ.get("HERMES_HOME"):
        candidates.append(Path(os.environ["HERMES_HOME"]) / "hermes-agent")
    candidates.append(Path.home() / ".hermes" / "hermes-agent")
    candidates.append(Path(os.environ.get("LOCALAPPDATA", "")) / "hermes" / "hermes-agent")
    for candidate in candidates:
        if candidate and (candidate / "hermes_cli" / "active_sessions.py").exists():
            return candidate
    raise SystemExit("hermes-agent source not found; set HERMES_REPO to its path")


HERMES_REPO = find_hermes_repo()
home = Path(tempfile.mkdtemp(prefix="session-lock-test-"))
(home / "runtime").mkdir(parents=True)
os.environ["HERMES_HOME"] = str(home)
sys.path.insert(0, str(HERMES_REPO))
sys.path.insert(0, str(PLUGIN_DIR))

import psutil  # noqa: E402
import plugin_api as api  # noqa: E402
from fastapi import HTTPException  # noqa: E402

failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(("  ok   " if condition else "  FAIL ") + name + (f"  [{detail}]" if detail and not condition else ""))
    if not condition:
        failures.append(name)


me = os.getpid()
my_start = psutil.Process(me).create_time()
now = time.time()
state = home / "runtime" / "active_sessions.json"

state.write_text(
    json.dumps(
        {
            "entries": [
                {
                    "lease_id": "lease-alive",
                    "session_id": "sess-alive",
                    "surface": "desktop",
                    "pid": me,
                    "process_start_time": my_start,
                    "started_at": now - 120,
                    "updated_at": now - 60,
                    "track_liveness": True,
                    "metadata": {"live_session_id": "abcd1234"},
                },
                {
                    "lease_id": "lease-dead",
                    "session_id": "sess-dead",
                    "surface": "remote",
                    "pid": 999999,
                    "process_start_time": my_start,
                    "started_at": now - 90000,
                    "updated_at": now - 90000,
                    "track_liveness": True,
                    "metadata": {},
                },
                {
                    "lease_id": "lease-recycled",
                    "session_id": "sess-recycled",
                    "surface": "desktop",
                    "pid": me,
                    "process_start_time": my_start - 5000,
                    "started_at": now - 5000,
                    "updated_at": now - 5000,
                    "track_liveness": True,
                    "metadata": {},
                },
            ]
        }
    ),
    encoding="utf-8",
)

print("\n[list]")
snap = api.list_leases()
by_id = {entry["session_id"]: entry for entry in snap["entries"]}
check("three leases listed", snap["count"] == 3, str(snap["count"]))
check("live owner reports alive=True", by_id["sess-alive"]["alive"] is True)
check("dead pid reports alive=False", by_id["sess-dead"]["alive"] is False)
check("recycled pid reports alive=False", by_id["sess-recycled"]["alive"] is False)

print("\n[scope=dead]")
res = api.release(api.ReleaseRequest(scope="dead"))
check(
    "only the two dead leases removed",
    sorted(e["session_id"] for e in res["removed"]) == ["sess-dead", "sess-recycled"],
    str([e["session_id"] for e in res["removed"]]),
)
check("the live lease survived", len(res["remaining"]) == 1)
check("backup file written", bool(res["backup"]) and Path(res["backup"]).exists())

print("\n[confirm gate]")
try:
    api.release(api.ReleaseRequest(scope="session", session_id="sess-alive"))
    check("session release without confirm is refused", False, "no exception")
except HTTPException as exc:
    check("session release without confirm is refused", exc.status_code == 400, str(exc.status_code))

print("\n[scope=session with confirm]")
res = api.release(api.ReleaseRequest(scope="session", session_id="sess-alive", confirm=True))
check("the live lease is removed", [e["session_id"] for e in res["removed"]] == ["sess-alive"])
check("registry is empty afterwards", len(res["remaining"]) == 0)

print("\n[audit + backups]")
audit = home / "runtime" / "session-lock-audit.log"
lines = audit.read_text(encoding="utf-8").splitlines() if audit.exists() else []
check("two audit lines", len(lines) == 2, str(len(lines)))
check("backups on disk", len(list((home / "runtime" / "session-lock-backups").glob("*.json"))) >= 1)

print("\n[corrupt registry]")
state.write_text("{not json", encoding="utf-8")
try:
    api.list_leases()
    check("corrupt registry is reported", False, "no exception")
except HTTPException as exc:
    check("corrupt registry is reported as 409", exc.status_code == 409, str(exc.status_code))
check("corrupt registry left untouched", state.read_text(encoding="utf-8") == "{not json")

print("\n" + ("FAILED: " + ", ".join(failures) if failures else "all checks passed"))
print(f"(temp home: {home})")
sys.exit(1 if failures else 0)
