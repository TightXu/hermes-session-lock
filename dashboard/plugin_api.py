"""Session-lock control backend, mounted at /api/plugins/session-lock/.

The desktop app refuses a message with SESSION_NOT_OWNED when another process holds the
session's lease in ``runtime/active_sessions.json``. That lease is process-scoped: a remote
``hermes serve`` or a laptop that dropped mid-turn can leave a stale entry behind, and the
code's own ``_prune_dead`` only reclaims it when the owning pid is gone.

These routes expose the registry and let the user drop entries on purpose:

  GET  /leases    -> every entry with its owner liveness and age
  POST /release   -> {"scope": "session" | "all" | "dead", "session_id"?: str}

Every write happens under the SAME file lock the runtime uses, backs the file up first, and
appends an audit line. Releasing a lease whose owner process is STILL ALIVE lets two clients
write one chat at once — that is why "session"/"all" need an explicit ``confirm`` and the UI
warns; "dead" only drops entries whose owner is provably gone.
"""
from __future__ import annotations

import json
import shutil
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from hermes_cli import active_sessions as registry
from hermes_constants import get_hermes_home

router = APIRouter()

_BACKUP_KEEP = 30


def _state_path() -> Path:
    return Path(get_hermes_home()) / "runtime" / "active_sessions.json"


def _lock_path() -> Path:
    return Path(get_hermes_home()) / "runtime" / "active_sessions.lock"


def _backup_dir() -> Path:
    return Path(get_hermes_home()) / "runtime" / "session-lock-backups"


def _audit_path() -> Path:
    return Path(get_hermes_home()) / "runtime" / "session-lock-audit.log"


def _load(state: Path) -> list[dict[str, Any]]:
    """Read the registry without the runtime's lenient fallbacks: a corrupt file must be
    reported, never silently replaced with an empty one."""
    if not state.exists():
        return []
    try:
        raw = json.loads(state.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # noqa: BLE001 - surfaced to the caller verbatim
        raise HTTPException(409, f"会话锁注册表不是合法 JSON：{exc}") from exc
    entries = raw.get("entries") if isinstance(raw, dict) else raw
    if not isinstance(entries, list):
        raise HTTPException(409, "会话锁注册表结构异常：缺少 entries 列表")
    return [entry for entry in entries if isinstance(entry, dict)]


def _backup(state: Path) -> str | None:
    if not state.exists():
        return None
    dest_dir = _backup_dir()
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"active_sessions-{time.strftime('%Y%m%d-%H%M%S')}.json"
    shutil.copy2(state, dest)
    olds = sorted(dest_dir.glob("active_sessions-*.json"))
    for stale in olds[:-_BACKUP_KEEP]:
        try:
            stale.unlink()
        except OSError:
            pass
    return str(dest)


def _audit(record: dict[str, Any]) -> None:
    try:
        path = _audit_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    except OSError:
        pass


def _session_titles(entries: list[dict[str, Any]]) -> dict[str, str]:
    """Resolve human session names for the lock rows.

    The lease registry only stores ids; the state DB is the source of truth for the
    title a person sees in the session list. Best effort: an unreadable/missing DB
    must never take the lock UI down, so callers fall back to the id.
    """
    ids = {
        str(entry.get("session_id") or "").strip()
        for entry in entries
        if str(entry.get("session_id") or "").strip()
    }
    if not ids:
        return {}
    try:
        from hermes_state import SessionDB

        with SessionDB(read_only=True) as db:
            titles: dict[str, str] = {}
            for sid in ids:
                title = (db.get_session_title(sid) or "").strip()
                if title:
                    titles[sid] = title
            return titles
    except Exception:  # noqa: BLE001 - titles are cosmetic, never a failure path
        return {}


def _describe(entry: dict[str, Any], now: float, title: str | None = None) -> dict[str, Any]:
    pid = entry.get("pid")
    try:
        alive: bool | None = registry._pid_liveness(pid, entry.get("process_start_time"))
    except Exception:  # noqa: BLE001 - liveness probe is best effort
        alive = None
    updated = entry.get("updated_at") or entry.get("started_at")
    age: float | None = None
    try:
        age = max(0.0, now - float(updated))
    except (TypeError, ValueError):
        age = None
    metadata = entry.get("metadata") if isinstance(entry.get("metadata"), dict) else {}
    return {
        "lease_id": str(entry.get("lease_id") or ""),
        "session_id": str(entry.get("session_id") or ""),
        "title": (title or "").strip() or None,
        "surface": str(entry.get("surface") or ""),
        "pid": pid,
        "alive": alive,
        "age_seconds": age,
        "updated_at": updated,
        "live_session_id": metadata.get("live_session_id"),
    }


@router.get("/leases")
def list_leases() -> dict[str, Any]:
    state = _state_path()
    with registry._FileLock(_lock_path(), timeout=5):
        entries = _load(state)
    now = time.time()
    titles = _session_titles(entries)
    return {
        "path": str(state),
        "count": len(entries),
        "entries": [
            _describe(entry, now, titles.get(str(entry.get("session_id") or "")))
            for entry in entries
        ],
    }


class ReleaseRequest(BaseModel):
    scope: str = "session"
    session_id: str | None = None
    confirm: bool = False


@router.post("/release")
def release(body: ReleaseRequest) -> dict[str, Any]:
    scope = (body.scope or "").strip().lower()
    if scope not in {"session", "all", "dead"}:
        raise HTTPException(400, "scope 只能是 session / all / dead")
    if scope == "session" and not (body.session_id or "").strip():
        raise HTTPException(400, "scope=session 需要 session_id")
    if scope in {"session", "all"} and not body.confirm:
        raise HTTPException(400, "强制释放活着的持有者需要 confirm=true")

    state, lock = _state_path(), _lock_path()
    removed: list[dict[str, Any]] = []
    with registry._FileLock(lock, timeout=5):
        entries = _load(state)
        keep: list[dict[str, Any]] = []
        for entry in entries:
            drop = False
            if scope == "all":
                drop = True
            elif scope == "session":
                drop = str(entry.get("session_id") or "") == body.session_id.strip()
            elif scope == "dead":
                try:
                    drop = registry._pid_liveness(
                        entry.get("pid"), entry.get("process_start_time")
                    ) is False
                except Exception:  # noqa: BLE001
                    drop = False
            if drop:
                removed.append(entry)
            else:
                keep.append(entry)
        backup = None
        if removed:
            backup = _backup(state)
            registry._write_entries(state, keep)
        remaining = _load(state)

    record = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "scope": scope,
        "session_id": body.session_id,
        "removed": [
            {
                "session_id": str(e.get("session_id") or ""),
                "pid": e.get("pid"),
                "surface": e.get("surface"),
            }
            for e in removed
        ],
        "remaining": len(remaining),
        "backup": backup,
    }
    if removed:
        _audit(record)
    now = time.time()
    titles = _session_titles(removed + remaining)
    return {
        "ok": True,
        "removed": [
            _describe(e, now, titles.get(str(e.get("session_id") or ""))) for e in removed
        ],
        "remaining": [
            _describe(e, now, titles.get(str(e.get("session_id") or ""))) for e in remaining
        ],
        "backup": backup,
        "path": str(state),
    }
