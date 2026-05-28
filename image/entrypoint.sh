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
        -exec chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" {} +
fi

exec gosu claude "$@"
