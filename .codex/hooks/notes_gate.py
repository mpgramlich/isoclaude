#!/usr/bin/env python3
"""notes_gate.py — a PORTABLE, stdlib-only note-taking gate (PreToolUse + PostToolUse).

WHAT IT ENFORCES
    Agents drift: they do work and forget to record what they did/learned. This gate
    keeps a running-log habit honest. It counts an agent's tool calls since its last
    NOTE, soft-nudges every NUDGE_EVERY calls, and once BLOCK_AT calls pass with no
    note it BLOCKS the next "work" tool (PreToolUse exit 2) until a note is logged.
    Logging a note is the ONLY thing that clears the counter.

    A "note" is a row that actually committed to the worktree's SQLite notes DB.
    Calls to the notes MCP tool (``mcp__notes__note_append``) and Bash calls that run
    the notes CLI are always allowed as escape hatches, but clear the gate only when
    the database's MAX(id) advances. A failed or spoofed tool call cannot reset it.

RELATION TO THE KNOB'S log-reminder.sh
    This generalizes that hook (per-session counter, byte-size freshness, fail-open,
    nudge/arm/block cadence) with two deliberate differences:
      * NOTE-DB-CENTRIC: the clear action is "log a note" (tool or CLI or mirror
        growth), not "edit one specific markdown file".
      * SUBAGENTS ARE NOT EXEMPT. log-reminder.sh early-exits on a subagent transcript
        path because it shared ONE global counter that concurrent lanes raced to the
        block. This gate keys the counter PER SESSION (sanitized session_id), so there
        is no shared-counter race — which makes it SAFE, and per the project directive
        REQUIRED, to hold subagents to the same log-or-block bar as the main session.

FAIL OPEN
    Any internal error prints nothing and exits 0. A hook bug must never wedge the
    agent. (Only the deliberate nudge/arm/block paths exit 2; those are SystemExit,
    not exceptions, so the fail-open guard never masks them.)

CONFIG (all env, all optional)
    NOTES_GATE_NUDGE_EVERY   soft-nudge cadence               (default 12)
    NOTES_GATE_BLOCK_AT      block the next work tool at      (default 20)
    NOTES_GATE_STATE_DIR     per-session counter dir          (default <script>/../.notesgate,
                                                               falling back to $TMPDIR)
    NOTES_GATE_DB            SQLite DB to verify (default <worktree>/.notes/notes.db)
    NOTES_GATE_MIRROR        optional mirror tracked for diagnostics only
    NOTES_GATE_NOTE_TOOL     substring identifying the note tool (default "note_append")
    NOTES_GATE_CLI_RE        regex identifying a Bash notes-CLI append
                             (default r"notes_mcp\\.py\\s+append|note[_-]append")
    NOTES_GATE_MESSAGE       extra guidance appended to the block text (default "")
"""

import os
import re
import sys
import json
import sqlite3
import tempfile


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

def _int_env(name, default):
    try:
        return int(str(os.environ.get(name, "")).strip())
    except (TypeError, ValueError):
        return default


def _state_dir():
    """Resolve the per-session state dir. Prefer NOTES_GATE_STATE_DIR; else a
    ``.notesgate`` next to this script's parent; fall back to $TMPDIR. Always returns a
    dir that exists (or raises — the caller's fail-open guard turns that into exit 0)."""
    override = os.environ.get("NOTES_GATE_STATE_DIR", "").strip()
    candidates = []
    if override:
        candidates.append(override)
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        candidates.append(os.path.normpath(os.path.join(here, "..", ".notesgate")))
    # Always keep a TMPDIR fallback so a read-only install dir can't wedge the gate.
    candidates.append(os.path.join(tempfile.gettempdir(), "notesgate"))
    for d in candidates:
        try:
            os.makedirs(d, exist_ok=True)
            return d
        except Exception:
            continue
    # Last resort: the system temp root itself (guaranteed writable).
    return tempfile.gettempdir()


def _vendored_cli_path():
    """Best-effort path to the vendored notes_mcp.py the message tells the agent to run.
    Installed layout is .claude/hooks/notes_gate.py alongside .claude/providers/
    notes_mcp.py, so ../providers/notes_mcp.py is the natural sibling."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "providers", "notes_mcp.py"))


def _repo_root():
    """Resolve the worktree from the installed hook path, independent of cwd."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", ".."))


def _db_path():
    path = os.environ.get("NOTES_GATE_DB", "").strip()
    if not path:
        return os.path.join(_repo_root(), ".notes", "notes.db")
    if not os.path.isabs(path):
        path = os.path.join(_repo_root(), path)
    return os.path.normpath(path)


def _max_note_id(path):
    """Return the durable append watermark, or 0 before the first note/schema."""
    if not os.path.isfile(path):
        return 0
    conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=1.0)
    try:
        row = conn.execute("SELECT COALESCE(MAX(id), 0) FROM notes").fetchone()
        return int(row[0] or 0)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Small IO helpers (all fail-soft)
# ---------------------------------------------------------------------------

def _sanitize_sid(sid):
    sid = str(sid or "").strip() or "default"
    return re.sub(r"[^A-Za-z0-9._-]", "_", sid)


def _read_int(path, default=0):
    try:
        with open(path) as f:
            return int((f.read().strip() or "0"))
    except Exception:
        return default


def _write_int(path, n):
    try:
        with open(path, "w") as f:
            f.write(str(int(n)))
    except Exception:
        pass


def _file_size(path):
    try:
        return os.path.getsize(path)
    except Exception:
        return 0


# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------

ALWAYS_ALLOW = {"Read", "Agent", "Task", "Workflow"}


def _mirror_grew(mirror, sizef):
    """Return (grew, current_size). Lazy-inits the baseline on first sight so a mirror
    that already had content when the agent started is NOT counted as a spurious note.
    When the size file is missing we record the current size and report grew=False."""
    if not mirror:
        return False, None
    cur = _file_size(mirror)
    seen = _read_int(sizef, default=-1)
    if seen < 0:
        # First observation: establish the baseline, do not treat as growth.
        _write_int(sizef, cur)
        return False, cur
    return (cur > seen), cur


def _decide():
    """Read the hook payload from stdin and return an exit code (0/2), emitting any
    nudge/arm/block text to stderr. Raises on unexpected internal errors — main()'s
    guard converts that to a fail-open exit 0."""
    raw = sys.stdin.read()
    payload = json.loads(raw)  # empty/malformed -> exception -> fail open (exit 0)
    if not isinstance(payload, dict):
        return 0

    event = str(payload.get("hook_event_name", "") or "")
    tool = str(payload.get("tool_name", "") or "")
    sid = _sanitize_sid(payload.get("session_id", ""))
    tin = payload.get("tool_input") or {}
    command = str(tin.get("command", "") or "")

    nudge_every = _int_env("NOTES_GATE_NUDGE_EVERY", 12)
    block_at = _int_env("NOTES_GATE_BLOCK_AT", 20)
    note_tool = os.environ.get("NOTES_GATE_NOTE_TOOL", "note_append")
    cli_re = os.environ.get(
        "NOTES_GATE_CLI_RE", r"notes_mcp\.py\s+append|note[_-]append"
    )
    mirror = os.environ.get("NOTES_GATE_MIRROR", "").strip()
    extra_msg = os.environ.get("NOTES_GATE_MESSAGE", "").strip()

    state_dir = _state_dir()
    countf = os.path.join(state_dir, sid + ".count")
    sizef = os.path.join(state_dir, sid + ".size")
    dbidf = os.path.join(state_dir, sid + ".dbid")

    # --- Is THIS call a note-event (the thing that clears the gate)? ---------
    grew, cur_size = _mirror_grew(mirror, sizef)
    # OR of three independent signals (NOT an elif chain: a Bash call whose command
    # does NOT match the CLI regex must still be allowed to count as a note-event via
    # mirror growth).
    is_note_attempt = False
    if note_tool and note_tool in tool:
        is_note_attempt = True
    if not is_note_attempt and tool == "Bash" and command:
        try:
            if re.search(cli_re, command):
                is_note_attempt = True
        except re.error:
            pass  # a bad custom regex must not wedge the gate

    # The DB watermark is authoritative. A tool-shaped call or mirror edit does not
    # clear the gate unless a SQLite row really committed.
    dbid = _max_note_id(_db_path())
    seen_dbid = _read_int(dbidf, default=-1)
    if seen_dbid < 0:
        _write_int(dbidf, dbid)
        seen_dbid = dbid
    db_advanced = dbid > seen_dbid

    n = _read_int(countf, default=0)

    cli_hint = _vendored_cli_path()

    def _how_to_log():
        return ("Log via the note_append tool (e.g. mcp__notes__note_append) or "
                "`python3 \"%s\" append --body \"...\"`. Logging a note is the ONLY "
                "thing that clears this gate — do NOT edit the counter or disable the "
                "hook." % cli_hint)

    if event == "PreToolUse":
        if n >= block_at and not is_note_attempt and tool not in ALWAYS_ALLOW:
            msg = ("NOTES GATE — BLOCKED: %d tool calls since your last note (this "
                   "session). Record what you have DONE / TRIED / LEARNED / RULED OUT "
                   "now. %s" % (n, _how_to_log()))
            if extra_msg:
                msg += " " + extra_msg
            sys.stderr.write(msg + "\n")
            return 2
        return 0

    if event == "PostToolUse":
        if db_advanced:
            _write_int(countf, 0)
            _write_int(dbidf, dbid)
            if mirror and cur_size is not None:
                _write_int(sizef, cur_size)
            return 0
        n += 1
        _write_int(countf, n)
        if n >= block_at:
            sys.stderr.write(
                "NOTES GATE ARMED (%d tool calls, no note logged): the NEXT work tool "
                "is BLOCKED until you log a note. %s\n" % (n, _how_to_log()))
            return 2
        if nudge_every > 0 and n % nudge_every == 0:
            sys.stderr.write(
                "NOTES GATE NUDGE (%d tool calls since your last note): append your "
                "latest findings/trials/dead-ends now — at %d the work tools are "
                "BLOCKED. %s\n" % (n, block_at, _how_to_log()))
            return 2
        return 0

    # Unknown event: do nothing.
    return 0


def main():
    try:
        code = _decide()
    except Exception:
        # FAIL OPEN — a hook bug must never wedge the agent.
        sys.exit(0)
    sys.exit(code)


if __name__ == "__main__":
    main()
