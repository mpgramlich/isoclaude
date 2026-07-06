#!/usr/bin/env sh
# isoclaude entrypoint.
#
# Runs briefly as root to remap the in-container `claude` user's UID/GID
# to match the host user (HOST_UID/HOST_GID env vars), then drops privs
# via gosu and execs the requested command.
#
# The bind-mounted dirs under /home/claude (.claude, .gitconfig, .ssh)
# are skipped during the home-dir chown so we don't mutate the host
# filesystem or trip over read-only mounts.

set -e

# Run usermod and silence the one known-harmless error — "Failed to
# change ownership of the home directory" — that trixie's usermod emits
# when its recursive chown_tree hits our read-only bind mounts
# (.gitconfig, .ssh, .claude/host-plugins). The passwd update is already
# committed by that point; our explicit chown below handles the
# writable parts. Other usermod errors still surface.
_usermod_quiet() {
    err=$(usermod "$@" 2>&1 >/dev/null) || true
    case "$err" in
        ""|*"Failed to change ownership of the home directory"*) ;;
        *) printf '%s\n' "$err" >&2 ;;
    esac
}

remap_gid() {
    target="$1"
    [ -n "$target" ] && [ "$target" != "$(id -g claude)" ] || return 0
    if getent group "$target" >/dev/null 2>&1; then
        # A group with this GID already exists (common: HOST_GID=20 is
        # macOS staff but also debian's dialout). Reassign claude to that
        # group as its primary rather than renaming the existing group.
        _usermod_quiet -g "$target" claude
    else
        groupmod -g "$target" claude
    fi
}

remap_uid() {
    target="$1"
    [ -n "$target" ] && [ "$target" != "$(id -u claude)" ] || return 0
    if getent passwd "$target" >/dev/null 2>&1 && \
       [ "$(getent passwd "$target" | cut -d: -f1)" != "claude" ]; then
        echo "isoclaude-entrypoint: HOST_UID=$target collides with existing container user" >&2
        exit 1
    fi
    _usermod_quiet -u "$target" claude
}

remap_gid "${HOST_GID:-${HOST_UID:-}}"
remap_uid "${HOST_UID:-}"

if [ -n "${HOST_UID:-}" ]; then
    chown "$HOST_UID:${HOST_GID:-$HOST_UID}" /home/claude

    # Re-own dotfiles/etc. inside the home dir, but skip the bind mounts.
    find /home/claude -mindepth 1 -maxdepth 1 \
        ! -name .claude \
        ! -name .gitconfig \
        ! -name .ssh \
        ! -name .isoclaude \
        -exec chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" {} +
fi

# Persisted-mode args override. When `isoclaude --keep` creates a
# container, it bind-mounts a host file at this path containing the
# argv to use. Each subsequent `isoclaude` in the same PWD rewrites
# that file before `container start`, so the restarted container picks
# up fresh args (different --resume id, --dangerously-skip-permissions,
# etc.) without being recreated. Skipped when the file isn't mounted,
# so ephemeral (--rm) runs are unaffected.
ARGS_FILE=/home/claude/.isoclaude/cmd
if [ -r "$ARGS_FILE" ]; then
    # shellcheck disable=SC2046,SC2086
    eval "set -- $(cat "$ARGS_FILE")"
fi

# Interactive claude goes through the pty mouse filter: claude's TUI
# enables xterm mouse-tracking unconditionally, which kills host-side
# drag-to-select (in tmux and out). The filter runs claude under a pty
# (so it still renders its TUI) and strips the mouse-enable sequences
# from the output stream. Gated on:
#   - the command actually being claude (bash/shell doesn't need it)
#   - stdout being a TTY (claude -p pipelines shouldn't grow a pty)
#   - ISOCLAUDE_MOUSE_FILTER != 0 (user opt-out for in-claude mouse)
#   - the filter actually being installed (older images: fall through)
case "${1:-}" in
    claude)
        if [ "${ISOCLAUDE_MOUSE_FILTER:-1}" != "0" ] && [ -t 1 ] \
           && command -v script >/dev/null 2>&1 \
           && [ -f /usr/local/lib/isoclaude/mouse-filter.js ]; then
            exec gosu claude /usr/local/bin/isoclaude-pty-filter "$@"
        fi
        ;;
esac

exec gosu claude "$@"
