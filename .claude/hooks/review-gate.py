#!/usr/bin/env python3
"""Review gate — HARD-blocks further edits until a BACKGROUND reviewer is launched.

MAIN-TREE-SCOPED (2026-07-10): the gate applies ONLY to the main project checkout
(CLAUDE_PROJECT_DIR — this session's live tree). Edits in any OTHER git worktree (workflow
lanes under /tmp/… or ~/wt-…) are EXEMPT: those are branch-isolated, ephemeral, and reviewed
by their own workflow Review phase, and their subagents lack the Agent/Workflow tool needed
to self-clear — so gating them was pure round-trip friction. The discipline stays where it
was designed to apply: the main session's own editing.

PER-WORKTREE SCOPED (2026-07-08). Registered for BOTH PreToolUse and PostToolUse over the
edit tools and the agent/workflow tools. Behaviour:

  * Each Edit/Write/MultiEdit/NotebookEdit increments an "unreviewed edits" counter for the
    GIT WORKTREE the edited file lives in — a separate count per worktree (state under
    .claude/.editcounts/<hash>, gitignored). Concurrent workflow lanes in different
    worktrees no longer tip each other's counters over; each gets its own budget.
  * Launching a BACKGROUND reviewer clears the debt for ALL worktrees — an Agent/Task call
    with run_in_background:true, or any Workflow call. (A review pass covers the working
    diff; one review unblocks every lane. Simple and predictable.)
  * A soft nudge fires every NUDGE_EVERY edits in a worktree.
  * Once a worktree's count reaches BLOCK_AT, the PreToolUse hook BLOCKS (exit 2) further
    edits TO THAT WORKTREE until a background reviewer is launched. The assistant must
    launch the reviewer, not work around the gate.

Fails OPEN: any internal error exits 0, so a hook bug can never wedge all editing.

Rationale: the assistant kept treating the async-review nudge as advisory and pushing past
it; a PreToolUse gate stops the next edit. Per-worktree scoping fixes the multi-lane case
where one workflow's edits blocked an unrelated lane sharing a single global counter.
"""
import os
import sys
import json
import hashlib

NUDGE_EVERY = 5     # soft-reminder cadence (edits, per worktree)
BLOCK_AT    = 10    # hard block once this many unreviewed edits in a worktree

EDIT_TOOLS  = ("Edit", "Write", "MultiEdit", "NotebookEdit")
AGENT_TOOLS = ("Agent", "Task")

root      = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
state_dir = os.path.join(root, ".claude", ".editcounts")


def edited_path(tool_input):
    """Absolute path of the file this edit targets, or None."""
    p = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not p:
        return None
    return os.path.abspath(p)


def worktree_root(path):
    """Walk up from `path` to the nearest dir containing a `.git` entry (file for a
    worktree, dir for the main checkout). Returns that dir, or None if not in a repo."""
    try:
        d = path if os.path.isdir(path) else os.path.dirname(path)
        prev = None
        while d and d != prev:
            if os.path.exists(os.path.join(d, ".git")):
                return d
            prev, d = d, os.path.dirname(d)
    except Exception:
        pass
    return None


def wt_key(tool_input):
    """Stable per-worktree key. Falls back to the project root when the edit is not
    inside any git worktree (e.g. scratch files), so those still get a (shared) budget."""
    p = edited_path(tool_input)
    wt = (worktree_root(p) if p else None) or root
    h = hashlib.sha1(wt.encode("utf-8", "replace")).hexdigest()[:12]
    return h, os.path.basename(wt.rstrip("/")) or wt, wt


def state_file(key):
    return os.path.join(state_dir, key)


def read_n(key):
    try:
        with open(state_file(key)) as f:
            return int(f.read().strip() or "0")
    except Exception:
        return 0


def write_n(key, n):
    try:
        os.makedirs(state_dir, exist_ok=True)
        tmp = state_file(key) + ".%d" % os.getpid()
        with open(tmp, "w") as f:
            f.write(str(n))
        os.replace(tmp, state_file(key))
    except Exception:
        pass


def clear_all():
    """Reset every worktree's counter (a background review covers the whole diff)."""
    try:
        if os.path.isdir(state_dir):
            for name in os.listdir(state_dir):
                try:
                    os.remove(os.path.join(state_dir, name))
                except Exception:
                    pass
        # legacy single-file counter from the pre-per-worktree hook
        legacy = os.path.join(root, ".claude", ".editcount")
        if os.path.exists(legacy):
            os.remove(legacy)
    except Exception:
        pass


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}

    event = payload.get("hook_event_name", "")
    tool  = payload.get("tool_name", "")
    tin   = payload.get("tool_input", {}) or {}

    # SUBAGENT-EXEMPT: this gate enforces the MAIN session's editing discipline. Workflow/Agent
    # subagents run their own Review phase and self-root their worktree, so gating them just wedges
    # them (they can't launch a background reviewer to self-clear). Detect a subagent by its
    # transcript path and never gate it.
    tp = str(payload.get("transcript_path", ""))
    if "/subagents/" in tp or "/tasks/" in tp:
        return 0

    # A background reviewer clears the debt — but ONLY a Workflow (or an Agent explicitly launched
    # with run_in_background:true). A plain Agent/Task call does NOT clear it: those are too cheap and
    # too frequent (reviewers, dream/investigation agents fire constantly) and were silently resetting
    # the counter so the gate never actually blocked. Real async review of the working diff goes through
    # the Workflow tool (devkit convention: "knob review-gate cleared by WORKFLOW calls, not Agent").
    if tool == "Workflow" or (tool in AGENT_TOOLS and
                              (tin.get("run_in_background") is True or
                               str(tin.get("run_in_background")).lower() == "true")):
        clear_all()
        return 0

    if tool not in EDIT_TOOLS:
        return 0

    # The running debug log is NOT code. The log-gate FORCES appends to DEBUG_NOTES.md; if those
    # appends accrued review debt here, the two gates deadlock (log-gate demands the write, this gate
    # blocks it). Exempt it — by EXACT path, before BOTH event branches (block-check and increment).
    _p = edited_path(tin)
    if _p:
        try:
            if os.path.realpath(_p) == os.path.realpath(os.path.join(root, "docs/hardware/DEBUG_NOTES.md")):
                return 0
        except Exception:
            pass

    key, label, wt = wt_key(tin)

    # MAIN-TREE-ONLY: exempt every worktree except this session's live project checkout.
    # Workflow/ephemeral worktrees are branch-isolated and have their own Review phase, and
    # their subagents can't self-clear — so gating them was pure friction, not discipline.
    try:
        if os.path.realpath(wt) != os.path.realpath(root):
            return 0
    except Exception:
        return 0

    n = read_n(key)

    if event == "PreToolUse":
        if n >= BLOCK_AT:
            sys.stderr.write(
                "REVIEW GATE — BLOCKED: {n} unreviewed edits in worktree '{w}'.\n"
                "Before editing again you MUST launch a BACKGROUND reviewer: an Agent call with "
                "run_in_background: true (or a Workflow) over the working diff, checking correctness "
                "AND duplication/simplification. Launching one clears the gate for every worktree; "
                "then re-issue the edit. Do NOT bypass (no editing the counter, no disabling the "
                "hook). If you are a workflow subagent without the Agent/Workflow tool, message "
                "'main' to have it launch the reviewer.".format(n=n, w=label))
            return 2
        return 0

    if event == "PostToolUse":
        n += 1
        write_n(key, n)
        if n >= BLOCK_AT:
            sys.stderr.write(
                "REVIEW GATE ARMED: {n} unreviewed edits in worktree '{w}' — the NEXT edit there "
                "is BLOCKED until a BACKGROUND reviewer is launched (Agent run_in_background, or a "
                "Workflow). Launch it now, then continue.".format(n=n, w=label))
            return 2
        if n % NUDGE_EVERY == 0:
            sys.stderr.write(
                "REVIEW NUDGE ({n}/{b} unreviewed edits in worktree '{w}'): launch a BACKGROUND "
                "reviewer over the working diff soon — at {b} you are blocked.".format(
                    n=n, b=BLOCK_AT, w=label))
            return 2
        return 0

    return 0


try:
    sys.exit(main())
except Exception:
    # Fail OPEN — a bug in the gate must never block all editing.
    sys.exit(0)
