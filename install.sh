#!/usr/bin/env bash
# install.sh — install isoclaude
#
# Copies bin/isoclaude to a prefix dir (default: ~/.local/bin if writable,
# else /usr/local/bin with sudo), seeds ~/.isoclaude/ with the base image
# files, writes the global version pin, and (by default) pre-builds the
# base image so the first `isoclaude` run isn't waiting on a build.
#
# Re-running is safe — it upgrades in place. To remove, run
# `isoclaude uninstall`.

set -eo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
NPM_PACKAGE="@anthropic-ai/claude-code"

PREFIX=""
NO_BUILD=0
VERSION=""
FORCE=0

usage() {
    cat <<EOF
usage: install.sh [OPTIONS]

  --prefix DIR      Install the wrapper to DIR (default: ~/.local/bin if
                    writable, otherwise /usr/local/bin).
  --version VER     Pin claude-code at VER instead of querying npm latest.
  --no-build        Don't pre-build the base image; defer to first run.
  --force           Overwrite an existing wrapper.
  -h, --help        Show this message.

After install: run \`isoclaude\` from any directory. If the prefix dir
isn't on your PATH, add it to your shell rc:
  export PATH="\$PREFIX:\$PATH"
EOF
}

log()  { printf '\033[2minstall:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33minstall:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31minstall:\033[0m %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)    PREFIX="$2"; shift 2 ;;
        --prefix=*)  PREFIX="${1#--prefix=}"; shift ;;
        --version)   VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#--version=}"; shift ;;
        --no-build)  NO_BUILD=1; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown arg: $1 (see --help)" ;;
    esac
done

# Sanity check: repo layout looks right.
[ -f "$REPO/bin/isoclaude" ] && [ -f "$REPO/image/Dockerfile.base" ] \
    && [ -f "$REPO/image/entrypoint.sh" ] \
    || die "$REPO doesn't look like the isoclaude repo (missing bin/ or image/)"

# Pick install prefix.
if [ -z "$PREFIX" ]; then
    if mkdir -p "$HOME/.local/bin" 2>/dev/null && [ -w "$HOME/.local/bin" ]; then
        PREFIX="$HOME/.local/bin"
    else
        PREFIX="/usr/local/bin"
    fi
fi
log "install prefix: $PREFIX"

# Surface runtime status (don't fail; user can install one later).
RUNTIME=""
for r in container orb docker podman; do
    if command -v "$r" >/dev/null 2>&1; then RUNTIME="$r"; break; fi
done
if [ -n "$RUNTIME" ]; then
    log "container runtime: $RUNTIME"
else
    warn "no container runtime on PATH (looked for: container, orb, docker, podman)"
    warn "install one before running isoclaude. See README."
fi

# Resolve the claude-code version to pin.
if [ -z "$VERSION" ]; then
    command -v npm >/dev/null 2>&1 \
        || die "'npm' not on PATH; install npm or pass --version=X.Y.Z"
    log "querying npm for latest $NPM_PACKAGE"
    VERSION="$(npm view "$NPM_PACKAGE" version --silent 2>/dev/null)" \
        || die "failed to query npm for latest $NPM_PACKAGE"
    [ -n "$VERSION" ] || die "npm returned empty version"
fi
log "pinning to claude $VERSION"

# Seed ~/.isoclaude/.
ISOCLAUDE_HOME="${ISOCLAUDE_HOME:-$HOME/.isoclaude}"
mkdir -p "$ISOCLAUDE_HOME"
cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
printf '%s\n' "$VERSION" > "$ISOCLAUDE_HOME/claude-version"
log "seeded $ISOCLAUDE_HOME"

# Install the wrapper.
DEST="$PREFIX/isoclaude"
mkdir -p "$PREFIX" 2>/dev/null || sudo mkdir -p "$PREFIX"

if [ -e "$DEST" ] && [ "$FORCE" -eq 0 ]; then
    if cmp -s "$REPO/bin/isoclaude" "$DEST"; then
        log "wrapper already up to date at $DEST"
    else
        die "wrapper exists at $DEST and differs from this repo; pass --force to overwrite"
    fi
else
    if [ -w "$PREFIX" ]; then
        cp "$REPO/bin/isoclaude" "$DEST"
        chmod +x "$DEST"
    else
        log "need sudo to write to $PREFIX"
        sudo cp "$REPO/bin/isoclaude" "$DEST"
        sudo chmod +x "$DEST"
    fi
    log "installed wrapper to $DEST"
fi

# Optional: pre-build the base image so first run is fast.
if [ "$NO_BUILD" -eq 0 ] && [ -n "$RUNTIME" ]; then
    log "pre-building base image (this may take a couple of minutes)"
    "$DEST" build || warn "pre-build failed; first \`isoclaude\` invocation will retry"
fi

# Final hint.
case ":$PATH:" in
    *":$PREFIX:"*)
        log "done — run \`isoclaude\` from any directory."
        ;;
    *)
        log "done — but $PREFIX is not on your PATH. Add to your shell rc:"
        log "  export PATH=\"$PREFIX:\$PATH\""
        ;;
esac
