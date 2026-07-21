#!/usr/bin/env python3
"""notes — a SQLite-backed notes MCP server.

WHY: agents were logging progress by *editing* docs/hardware/DEBUG_NOTES.md. On a
Google-Drive FUSE mount that append races (mtime-only syncs, partial writes) and
multiple concurrent subagents clobber each other's appends. This server replaces the
file edit with a TOOL CALL: each note is one parameterized INSERT into a SQLite DB on
the LOCAL container FS (never the FUSE path — SQLite over a network FS corrupts). WAL
mode + a busy_timeout let SQLite itself serialize concurrent subagent + main-loop
writes safely, with no flock and no threading.Lock.

The DB is canonical. The Drive DEBUG_NOTES.md "mirror" is a best-effort convenience
view appended off the hot path; any FUSE error there is swallowed and never fails the
append (the mirror is fully regenerable via note_render).

Transport: prefers the `mcp` SDK (FastMCP) if importable at runtime; otherwise falls
back to a dependency-free, hand-rolled stdio JSON-RPC 2.0 server (stdlib only). This
matters because the container HOME is ephemeral — a pip-installed `mcp` may be gone by
the session that actually launches this server, and the stdlib fallback still works.

Env:
  NOTES_DB       — override the DB path (default <repo>/.notes/notes.db when
                   vendored or launched inside a git worktree; otherwise
                   $HOME/.claude/notes/notes.db)
  NOTES_MIRROR   — Drive mirror file to best-effort append to
                   (default docs/hardware/DEBUG_NOTES.md; empty string disables)
  NOTES_DEFAULT_AUTHOR — override the per-process default author
  NOTES_MCP_MODE — "fastmcp" | "stdio" to force a transport (default: auto)
"""

import os
import sys
import json
import uuid
import sqlite3
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Configuration / small helpers
# ---------------------------------------------------------------------------

# A default author, generated ONCE per process (== once per stdio connection), so a
# write is NEVER anonymous even if the caller omits `author`.
_DEFAULT_AUTHOR = os.environ.get("NOTES_DEFAULT_AUTHOR") or ("agent-" + uuid.uuid4().hex[:8])

# The markdown mirror is OPT-IN: disabled unless NOTES_MIRROR is set. A standalone
# repo must not bake in a machine-specific path; the SQLite DB is the canonical store
# and the mirror is a regenerable convenience view (see note_render).
_DEFAULT_MIRROR = ""

MAX_LIMIT = 1000


def _find_repo_root() -> str | None:
    """Find the owning worktree without invoking git.

    Vendored providers live at ``<repo>/.claude/providers`` or
    ``<repo>/.codex/providers``.  Walking from both cwd and ``__file__`` also
    covers the standalone development checkout and callers launched below the
    repository root.  A git worktree's ``.git`` may be either a directory or a
    file, so existence is the only test that is safe here.
    """
    # Prefer the provider's installed location.  MCP clients normally launch it
    # from the project root, but the CLI is also used from orchestration shells
    # whose cwd may be a different fleet repository.  Looking at cwd first can
    # silently put a worktree's notes in that unrelated repository.
    starts = [os.path.dirname(os.path.abspath(__file__)), os.getcwd()]
    seen = set()
    for start in starts:
        cur = os.path.abspath(start)
        while cur not in seen:
            seen.add(cur)
            if os.path.exists(os.path.join(cur, ".git")):
                return cur
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
    return None


def _db_path() -> str:
    """Resolve the DB path. Read from env each call so tests can point at a temp DB."""
    p = os.environ.get("NOTES_DB", "").strip()
    if p:
        return p
    root = _find_repo_root()
    if root:
        return os.path.join(root, ".notes", "notes.db")
    home = os.environ.get("HOME") or os.path.expanduser("~")
    return os.path.join(home, ".claude", "notes", "notes.db")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _coerce_tags(tags):
    """Store tags as TEXT. Accept a list/tuple (join with ',') or a plain string."""
    if tags is None:
        return None
    if isinstance(tags, (list, tuple)):
        return ",".join(str(t).strip() for t in tags if str(t).strip()) or None
    s = str(tags).strip()
    return s or None


def _connect(db_path: str | None = None) -> sqlite3.Connection:
    """Open the DB (creating dir + schema) in WAL mode with sane concurrency PRAGMAs."""
    path = db_path or _db_path()
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    conn = sqlite3.connect(path, timeout=5.0)
    conn.row_factory = sqlite3.Row
    # WAL persists in the DB header (idempotent); synchronous + busy_timeout are
    # per-connection and must be set each open. These let SQLite serialize concurrent
    # cross-process writers itself — no external lock needed.
    # Arm busy_timeout BEFORE switching journal_mode: on a COLD db the WAL conversion
    # itself takes a write lock, so a swarm of first-openers can hit 'database is
    # locked' before the timeout exists. Order matters.
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    _init_db(conn)
    return conn


def _init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS notes(
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            ts       TEXT NOT NULL,
            author   TEXT NOT NULL,
            agent_id TEXT,
            session  TEXT,
            project  TEXT,
            phase    TEXT,
            tags     TEXT,
            body     TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_notes_project ON notes(project);
        CREATE INDEX IF NOT EXISTS idx_notes_author  ON notes(author);
        CREATE INDEX IF NOT EXISTS idx_notes_ts      ON notes(ts);
        """
    )
    conn.commit()


def _row_to_dict(r: sqlite3.Row) -> dict:
    return {k: r[k] for k in r.keys()}


# ---------------------------------------------------------------------------
# Rendering (shared by the Drive mirror and note_render)
# ---------------------------------------------------------------------------

def _render_line(row: dict) -> str:
    """One compact markdown bullet for a note. Body newlines collapse to ' / ' so the
    mirror stays one-line-per-note and easy to eyeball."""
    meta = []
    if row.get("project"):
        meta.append(f"project={row['project']}")
    if row.get("phase"):
        meta.append(f"phase={row['phase']}")
    if row.get("tags"):
        meta.append(f"tags={row['tags']}")
    if row.get("agent_id"):
        meta.append(f"agent={row['agent_id']}")
    metastr = (" [" + " ".join(meta) + "]") if meta else ""
    body = row.get("body") or ""
    body = " / ".join(s for s in body.splitlines() if s.strip()) or body.strip()
    return f"- `#{row.get('id')}` {row.get('ts')} · **{row.get('author')}**{metastr} — {body}"


def _render_notes(rows) -> str:
    if not rows:
        return "_(no notes)_"
    return "\n".join(_render_line(r) for r in rows)


def _mirror_append(row: dict) -> None:
    """Best-effort: append one rendered line to the Drive mirror. NEVER raises — the DB
    is canonical; the mirror is a regenerable convenience view. Any FUSE/IO error is
    swallowed so a mirror failure can never fail (or slow) the canonical append."""
    try:
        mirror = os.environ.get("NOTES_MIRROR", _DEFAULT_MIRROR)
        if mirror is None or mirror.strip() == "":
            return
        line = _render_line(row) + "\n"
        with open(mirror, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        # Deliberately silent: mirror is best-effort and OFF the hot path.
        pass


# ---------------------------------------------------------------------------
# Tool implementations (pure functions — importable by tests; DB path via env)
# ---------------------------------------------------------------------------

def note_append(
    body: str,
    author: str | None = None,
    tags: str | None = None,
    phase: str | None = None,
    project: str | None = None,
    agent_id: str | None = None,
    session: str | None = None,
) -> dict:
    """Append one note (a single INSERT) and return its stable ROWID.

    `author` defaults to a per-process UUID so a write is never anonymous. Returns
    {id, ts, author}; `id` is the stable "line number" for later reference/render.
    After the committed INSERT, best-effort appends the rendered line to the Drive
    mirror (never blocks or fails the append)."""
    if body is None or str(body).strip() == "":
        raise ValueError("note_append: 'body' is required and must be non-empty")
    body = str(body)
    author = (author or "").strip() or _DEFAULT_AUTHOR
    tags = _coerce_tags(tags)
    ts = _now_iso()

    conn = _connect()
    try:
        cur = conn.execute(
            "INSERT INTO notes(ts, author, agent_id, session, project, phase, tags, body) "
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
            (ts, author, agent_id, session, project, phase, tags, body),
        )
        conn.commit()
        rid = cur.lastrowid
    finally:
        conn.close()

    _mirror_append(
        {
            "id": rid,
            "ts": ts,
            "author": author,
            "agent_id": agent_id,
            "session": session,
            "project": project,
            "phase": phase,
            "tags": tags,
            "body": body,
        }
    )
    return {"id": rid, "ts": ts, "author": author}


def note_query(
    project: str | None = None,
    author: str | None = None,
    since: str | None = None,
    until: str | None = None,
    tags: str | None = None,
    phase: str | None = None,
    grep: str | None = None,
    limit: int = 50,
) -> dict:
    """Query notes by any provided column; newest first. `grep` matches body LIKE
    %grep%, `tags` matches tags LIKE %tags%, `since`/`until` bound ts (ISO strings
    sort lexicographically). Returns {rows: [...]}. All SQL is parameterized."""
    where, params = [], []
    if project:
        where.append("project = ?"); params.append(project)
    if author:
        where.append("author = ?"); params.append(author)
    if since:
        where.append("ts >= ?"); params.append(since)
    if until:
        where.append("ts <= ?"); params.append(until)
    if phase:
        where.append("phase = ?"); params.append(phase)
    if tags:
        where.append("tags LIKE ?"); params.append(f"%{tags}%")
    if grep:
        where.append("body LIKE ?"); params.append(f"%{grep}%")

    try:
        lim = int(limit)
    except (TypeError, ValueError):
        lim = 50
    lim = max(1, min(lim, MAX_LIMIT))

    sql = "SELECT * FROM notes"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY id DESC LIMIT ?"
    params.append(lim)

    conn = _connect()
    try:
        rows = [_row_to_dict(r) for r in conn.execute(sql, params).fetchall()]
    finally:
        conn.close()
    return {"rows": rows}


def note_render(
    project: str | None = None,
    since: str | None = None,
    ids: list | None = None,
    tail: int | None = None,
) -> dict:
    """Render matching notes to a readable markdown block. Select by explicit `ids`,
    or `tail=N` (the most recent N), and/or filter by `project`/`since`. Returns
    {markdown}. All SQL is parameterized."""
    where, params = [], []
    if ids:
        try:
            id_ints = [int(i) for i in ids]
        except (TypeError, ValueError):
            id_ints = []
        if id_ints:
            where.append("id IN (%s)" % ",".join("?" for _ in id_ints))
            params.extend(id_ints)
    if project:
        where.append("project = ?"); params.append(project)
    if since:
        where.append("ts >= ?"); params.append(since)

    sql = "SELECT * FROM notes"
    if where:
        sql += " WHERE " + " AND ".join(where)

    reverse_after = False
    if tail and not ids:
        try:
            n = max(1, min(int(tail), MAX_LIMIT))
        except (TypeError, ValueError):
            n = 50
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(n)
        reverse_after = True  # fetch newest-N, then present oldest→newest
    else:
        sql += " ORDER BY id ASC"

    conn = _connect()
    try:
        rows = [_row_to_dict(r) for r in conn.execute(sql, params).fetchall()]
    finally:
        conn.close()
    if reverse_after:
        rows.reverse()
    return {"markdown": _render_notes(rows)}


# ---------------------------------------------------------------------------
# Token-gated edit: retag an existing note (the log is otherwise append-only)
# ---------------------------------------------------------------------------

def _mirror_regenerate() -> None:
    """Best-effort: rewrite the WHOLE Drive mirror from the DB. Used after an edit that
    changes an existing note (an append would leave the stale line behind). Never raises
    — the DB is canonical; the mirror is a regenerable convenience view."""
    try:
        mirror = os.environ.get("NOTES_MIRROR", _DEFAULT_MIRROR)
        if not (mirror and str(mirror).strip()):
            return
        conn = _connect()
        try:
            rows = [_row_to_dict(r) for r in
                    conn.execute("SELECT * FROM notes ORDER BY id ASC").fetchall()]
        finally:
            conn.close()
        with open(mirror, "w", encoding="utf-8") as f:
            f.write(_render_notes(rows) + "\n")
    except Exception:
        pass


def note_retag(note_id: int, tags: str, token: str | None = None) -> dict:
    """Replace an existing note's tags. The notes log is APPEND-ONLY by design; this is
    the ONLY mutation path and it is GATED by a shared edit token so a stray writer can
    never silently rewrite the log. The caller MUST pass `token` matching the server's
    NOTES_EDIT_TOKEN (which must itself be set + non-empty, else edits are disabled
    entirely). Reads (query/render) are UNGATED — crawl freely. Returns {id, tags} and
    regenerates the mirror (a retag changes an existing line)."""
    expected = (os.environ.get("NOTES_EDIT_TOKEN") or "").strip()
    if not expected:
        raise PermissionError("note_retag: edits are disabled (NOTES_EDIT_TOKEN unset)")
    if not token or str(token) != expected:
        raise PermissionError("note_retag: bad or missing edit token")
    try:
        nid = int(note_id)
    except (TypeError, ValueError):
        raise ValueError("note_retag: note_id must be an integer")
    new_tags = _coerce_tags(tags)

    conn = _connect()
    try:
        cur = conn.execute("UPDATE notes SET tags=? WHERE id=?", (new_tags, nid))
        conn.commit()
        n = cur.rowcount
    finally:
        conn.close()
    if n == 0:
        raise ValueError(f"note_retag: no note with id {nid}")
    _mirror_regenerate()
    return {"id": nid, "tags": new_tags}


# ---------------------------------------------------------------------------
# Tool metadata (single source of truth for the hand-rolled JSON-RPC schemas)
# ---------------------------------------------------------------------------

_STR = {"type": "string"}

TOOLS = [
    {
        "name": "note_append",
        "description": (
            "Append one note to the canonical SQLite log (one INSERT) and return its "
            "stable ROWID. Use this INSTEAD of editing DEBUG_NOTES.md — it is race-free "
            "across concurrent agents. author defaults to a per-agent id so a note is "
            "never anonymous. Returns {id, ts, author}."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "body": {"type": "string", "description": "The note text (required, non-empty)."},
                "author": {"type": "string", "description": "Who is writing (defaults to a per-agent id)."},
                "tags": {"type": "string", "description": "Comma-separated tags."},
                "phase": {"type": "string", "description": "Workflow phase/stage."},
                "project": {"type": "string", "description": "Project/component this note is about."},
                "agent_id": {"type": "string", "description": "Subagent/lane id, if any."},
                "session": {"type": "string", "description": "Session id, if any."},
            },
            "required": ["body"],
        },
    },
    {
        "name": "note_query",
        "description": (
            "Query notes by any column (project/author/phase), a ts window "
            "(since/until), tags substring, or body grep. Newest first. Returns "
            "{rows:[...]}. limit defaults to 50."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": _STR,
                "author": _STR,
                "since": {"type": "string", "description": "ISO ts lower bound (ts >= since)."},
                "until": {"type": "string", "description": "ISO ts upper bound (ts <= until)."},
                "tags": {"type": "string", "description": "Substring match on tags."},
                "phase": _STR,
                "grep": {"type": "string", "description": "Substring match on body."},
                "limit": {"type": "integer", "description": "Max rows (default 50).", "default": 50},
            },
        },
    },
    {
        "name": "note_render",
        "description": (
            "Render matching notes to a readable markdown block. Select by explicit "
            "ids, or tail=N (most recent N), and/or filter by project/since. Returns "
            "{markdown}."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": _STR,
                "since": {"type": "string", "description": "ISO ts lower bound."},
                "ids": {"type": "array", "items": {"type": "integer"}, "description": "Explicit note ids."},
                "tail": {"type": "integer", "description": "Render the most recent N notes."},
            },
        },
    },
    {
        "name": "note_retag",
        "description": (
            "Replace an existing note's tags — the ONLY edit path (the log is otherwise "
            "append-only). GATED: requires `token` matching the server's NOTES_EDIT_TOKEN. "
            "Reads (query/render) are ungated. Returns {id, tags}."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "note_id": {"type": "integer", "description": "id of the note to retag."},
                "tags": {"type": "string", "description": "Comma-separated tags (replaces existing)."},
                "token": {"type": "string", "description": "Safe-edit token (must match NOTES_EDIT_TOKEN)."},
            },
            "required": ["note_id", "tags", "token"],
        },
    },
]

_DISPATCH = {
    "note_append": note_append,
    "note_query": note_query,
    "note_render": note_render,
    "note_retag": note_retag,
}


# ---------------------------------------------------------------------------
# Transport A: FastMCP (preferred when the `mcp` SDK is importable)
# ---------------------------------------------------------------------------

def run_fastmcp() -> None:
    from mcp.server.fastmcp import FastMCP

    mcp = FastMCP("notes")
    # Register the pure impl functions directly; FastMCP derives the input schema from
    # their type hints + docstrings.
    mcp.tool()(note_append)
    mcp.tool()(note_query)
    mcp.tool()(note_render)
    mcp.tool()(note_retag)
    mcp.run()


# ---------------------------------------------------------------------------
# Transport B: hand-rolled stdio JSON-RPC 2.0 (stdlib only, zero deps)
# ---------------------------------------------------------------------------
# MCP stdio framing = newline-delimited JSON-RPC messages (one JSON object per line,
# no embedded newlines). We read a line, dispatch, and write one JSON line back.

_PROTOCOL_VERSION = "2025-06-18"
_SERVER_INFO = {"name": "notes", "version": "1.0.0"}


def _send(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _result(req_id, result) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "result": result})


def _error(req_id, code, message) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": str(message)}})


def _handle_tools_call(req_id, params) -> None:
    name = (params or {}).get("name")
    args = (params or {}).get("arguments") or {}
    fn = _DISPATCH.get(name)
    if fn is None:
        # Fail-open: return an isError tool result rather than a protocol error so the
        # session is never killed by a bad tool name.
        _result(req_id, {
            "content": [{"type": "text", "text": f"unknown tool: {name}"}],
            "isError": True,
        })
        return
    try:
        out = fn(**args)
        _result(req_id, {
            "content": [{"type": "text", "text": json.dumps(out, ensure_ascii=False)}],
            "structuredContent": out,
            "isError": False,
        })
    except Exception as e:  # noqa: BLE001 — fail-open: surface as tool error, never crash
        _result(req_id, {
            "content": [{"type": "text", "text": f"{type(e).__name__}: {e}"}],
            "isError": True,
        })


def run_stdio() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            # Can't recover an id from an unparseable line; skip it (fail-open).
            continue

        method = req.get("method")
        req_id = req.get("id")
        params = req.get("params") or {}
        is_notification = "id" not in req

        try:
            if method == "initialize":
                client_ver = params.get("protocolVersion")
                _result(req_id, {
                    "protocolVersion": client_ver or _PROTOCOL_VERSION,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": _SERVER_INFO,
                })
            elif method in ("notifications/initialized", "initialized"):
                pass  # notification; no response
            elif method == "ping":
                _result(req_id, {})
            elif method == "tools/list":
                _result(req_id, {"tools": TOOLS})
            elif method == "tools/call":
                _handle_tools_call(req_id, params)
            elif is_notification:
                pass  # unknown notification: ignore
            else:
                _error(req_id, -32601, f"method not found: {method}")
        except Exception as e:  # noqa: BLE001 — never let one bad message kill the loop
            if not is_notification:
                _error(req_id, -32603, f"internal error: {e}")


# ---------------------------------------------------------------------------
# Transport C: a plain argparse CLI (append / query / render)
# ---------------------------------------------------------------------------
# WHY: the notes DB is also the running log a PreToolUse/PostToolUse *gate* enforces
# (see hooks/notes_gate.py). An agent that has the MCP `note_append` tool logs through
# that; an agent driving a plain shell (or a CI job, or `install.sh`'s own dogfooding)
# logs through THIS CLI. Both funnel into the same note_append()/note_query()/
# note_render() pure functions, so the DB is identical no matter the entry point.
#
# main() dispatches to the CLI ONLY when the first argv is a known subcommand; with no
# subcommand it falls through UNCHANGED to the MCP stdio/fastmcp server (that is how the
# MCP client launches it — `python3 notes_mcp.py` with no args), so the server never
# regresses.

_CLI_COMMANDS = ("append", "query", "render", "retag")


def _build_cli_parser():
    import argparse

    parser = argparse.ArgumentParser(
        prog="notes_mcp.py",
        description="notes CLI — append/query/render the SQLite notes log "
                    "(same store the MCP tools and the note-taking gate use).",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    ap = sub.add_parser("append", help="append one note; prints {id,ts,author} JSON")
    ap.add_argument("--body", required=True, help="note text (required, non-empty)")
    ap.add_argument("--author", help="who is writing (defaults to a per-process id)")
    ap.add_argument("--project", help="project/component this note is about")
    ap.add_argument("--phase", help="workflow phase/stage")
    ap.add_argument("--agent-id", dest="agent_id", help="subagent/lane id, if any")
    ap.add_argument("--session", help="session id, if any")
    ap.add_argument("--tags", help="comma-separated tags")

    qp = sub.add_parser("query", help="query notes; prints {rows:[...]} JSON")
    qp.add_argument("--project")
    qp.add_argument("--author")
    qp.add_argument("--phase")
    qp.add_argument("--grep", help="substring match on body")
    qp.add_argument("--tags", help="substring match on the tag list")
    qp.add_argument("--since", help="ISO ts lower bound (ts >= since)")
    qp.add_argument("--until", help="ISO ts upper bound (ts <= until)")
    qp.add_argument("--limit", type=int, default=50, help="max rows (default 50)")

    rp = sub.add_parser("render", help="render matching notes to markdown")
    rp.add_argument("--tail", type=int, help="render the most recent N notes")
    rp.add_argument("--project")
    rp.add_argument("--since", help="ISO ts lower bound")
    rp.add_argument("--id", dest="ids", action="append",
                    help="explicit note id (repeatable)")

    tp = sub.add_parser("retag",
                        help="replace an existing note's tags (requires --token; the log is otherwise append-only)")
    tp.add_argument("--id", dest="note_id", required=True, type=int, help="id of the note to retag")
    tp.add_argument("--tags", required=True, help="comma-separated tags (replaces existing)")
    tp.add_argument("--token", required=True, help="safe-edit token (must match NOTES_EDIT_TOKEN)")

    return parser


def run_cli(argv) -> int:
    """Dispatch a CLI invocation. Returns a process exit code."""
    parser = _build_cli_parser()
    args = parser.parse_args(argv)

    if args.cmd == "append":
        out = note_append(
            body=args.body, author=args.author, tags=args.tags,
            phase=args.phase, project=args.project,
            agent_id=args.agent_id, session=args.session,
        )
        print(json.dumps(out, ensure_ascii=False))
    elif args.cmd == "query":
        out = note_query(
            project=args.project, author=args.author, phase=args.phase,
            grep=args.grep, tags=args.tags, since=args.since,
            until=args.until, limit=args.limit,
        )
        print(json.dumps(out, ensure_ascii=False))
    elif args.cmd == "render":
        out = note_render(
            project=args.project, since=args.since, ids=args.ids, tail=args.tail,
        )
        print(out["markdown"])
    elif args.cmd == "retag":
        out = note_retag(args.note_id, args.tags, token=args.token)
        print(json.dumps(out, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    # CLI dispatch FIRST: if the first argument is a known subcommand, run the CLI and
    # exit. Anything else (notably NO arguments) falls through to the MCP server below,
    # which must stay byte-for-byte the prior behaviour — the MCP client always launches
    # this file with no subcommand.
    argv = sys.argv[1:]
    if argv and argv[0] in _CLI_COMMANDS:
        sys.exit(run_cli(argv))

    mode = os.environ.get("NOTES_MCP_MODE", "").strip().lower()
    if mode == "stdio":
        run_stdio()
        return
    if mode == "fastmcp":
        run_fastmcp()
        return
    # auto: prefer FastMCP if the SDK is importable/startable at runtime; on ANY
    # failure fall back to the dependency-free stdio server so the session never loses
    # its notes tools (the container HOME is ephemeral — mcp may not be installed).
    try:
        import mcp  # noqa: F401
        run_fastmcp()
    except Exception:
        try:
            run_stdio()
        except Exception:
            sys.exit(0)


if __name__ == "__main__":
    main()
