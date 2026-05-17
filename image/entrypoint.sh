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

if [ -n "$HOST_UID" ] && [ "$HOST_UID" != "$(id -u claude)" ]; then
    usermod  -u "$HOST_UID" claude >/dev/null
    groupmod -g "${HOST_GID:-$HOST_UID}" claude >/dev/null

    chown "$HOST_UID:${HOST_GID:-$HOST_UID}" /home/claude

    # Re-own dotfiles/etc. inside the home dir, but skip the bind mounts.
    find /home/claude -mindepth 1 -maxdepth 1 \
        ! -name .claude \
        ! -name .gitconfig \
        ! -name .ssh \
        -exec chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" {} +
fi

exec gosu claude "$@"
