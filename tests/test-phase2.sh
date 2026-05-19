#!/usr/bin/env bash
# Phase 2 tests: bin/isoclaude wrapper.
#
# Sources the wrapper (the if-not-sourced guard prevents main() running)
# and exercises individual functions, with a tmp HOME and a fake docker
# binary on PATH so nothing real gets invoked.

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO/bin/isoclaude"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

#-----------------------------------------------------------------------
section "Static checks"

bash -n "$WRAPPER" && ok "bash -n parses wrapper" || bad "bash -n failed"
[ -x "$WRAPPER" ] && ok "wrapper is executable" || bad "wrapper not executable"
head -1 "$WRAPPER" | grep -q '^#!/usr/bin/env bash$' \
    && ok "uses /usr/bin/env bash shebang" || bad "wrong shebang"
# Strip comment lines before grepping so the "avoid X" comments don't trip us.
code_only() { grep -v '^[[:space:]]*#' "$WRAPPER"; }
code_only | grep -q '\bmapfile\b' \
    && bad "uses bash 4 mapfile" "won't work on macOS bash 3.2" \
    || ok "no mapfile in code (bash 3.2 safe)"
code_only | grep -q '\breadarray\b' \
    && bad "uses bash 4 readarray" "won't work on macOS bash 3.2" \
    || ok "no readarray in code (bash 3.2 safe)"

#-----------------------------------------------------------------------
section "Test harness setup"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake docker that records its argv so we can inspect what would be run.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: log argv, fake image-inspect/build behavior driven by env.
echo "$@" >> "$FAKE_DOCKER_LOG"
case "$1" in
    image)
        if [ "$2" = "inspect" ]; then
            # Emit docker-style JSON when a label is configured; exit nonzero otherwise.
            if [ -n "${FAKE_LABEL:-}" ]; then
                printf '[{"Config":{"Labels":{"isoclaude.claude_version":"%s"}}}]\n' "$FAKE_LABEL"
                exit 0
            fi
            exit 1
        fi
        ;;
    build)
        # Pretend build succeeded.
        exit 0
        ;;
    run)
        # Pretend run succeeded (we'll mostly use DRY_RUN to skip exec anyway).
        exit 0
        ;;
esac
exit 0
EOF
chmod +x "$TMP/fakebin/docker"

# Isolate HOME and PATH.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$HOME/.ssh"
echo "[user]" > "$HOME/.gitconfig"
echo "fake-key" > "$HOME/.ssh/id_ed25519"
echo '{}' > "$HOME/.claude.json"

export ISOCLAUDE_HOME="$HOME/.isoclaude"
export ISOCLAUDE_RUNTIME="docker"
export ISOCLAUDE_BASE_IMAGE="isoclaude-base:test"
export FAKE_DOCKER_LOG="$TMP/docker.log"
: > "$FAKE_DOCKER_LOG"
ORIG_PATH="$PATH"
export PATH="$TMP/fakebin:$PATH"

ok "tmp HOME=$HOME"
ok "fake docker on PATH at $TMP/fakebin/docker"

# Source the wrapper so its functions are callable.
# shellcheck disable=SC1090
. "$WRAPPER"
ok "wrapper sourced without executing main"

#-----------------------------------------------------------------------
section "detect_runtime"

unset ISOCLAUDE_RUNTIME
# Seal PATH to only the fakebin dir so a real container/orb/podman install
# on the host doesn't shadow our fake docker.
got="$(PATH="$TMP/fakebin" detect_runtime)"
[ "$got" = "docker" ] && ok "auto-detects docker from sealed PATH" || bad "auto-detect" "got '$got'"

export ISOCLAUDE_RUNTIME="docker"
got="$(detect_runtime)"
[ "$got" = "docker" ] && ok "honors ISOCLAUDE_RUNTIME override" || bad "override" "got '$got'"

export ISOCLAUDE_RUNTIME="not-a-real-runtime-xyz"
if got="$(detect_runtime 2>&1)"; then
    bad "rejects missing runtime" "should have errored, got '$got'"
else
    ok "errors when ISOCLAUDE_RUNTIME is missing from PATH"
fi
export ISOCLAUDE_RUNTIME="docker"

#-----------------------------------------------------------------------
section "project_root discovery"

mkdir -p "$TMP/proj/sub/deeper"
( cd "$TMP/proj/sub/deeper"; got="$(project_root)"; [ -z "$got" ] ) \
    && ok "returns empty when no .isoclaude/ above" \
    || bad "no-.isoclaude case" "got '$(cd "$TMP/proj/sub/deeper"; project_root)'"

mkdir -p "$TMP/proj/.isoclaude"
( cd "$TMP/proj/sub/deeper"; got="$(project_root)"; [ "$got" = "$TMP/proj" ] ) \
    && ok "finds .isoclaude/ several levels up" \
    || bad "upward search" "got '$(cd "$TMP/proj/sub/deeper"; project_root)'"

( cd "$TMP/proj"; got="$(project_root)"; [ "$got" = "$TMP/proj" ] ) \
    && ok "finds .isoclaude/ in current dir" \
    || bad "current-dir case"

# Regression: ISOCLAUDE_HOME=$HOME/.isoclaude is the wrapper's own config dir,
# NOT a project root. Walking up from a child shouldn't find $HOME as project.
mkdir -p "$HOME/.isoclaude"   # simulate the wrapper's global config dir
mkdir -p "$HOME/child"
( cd "$HOME/child" && [ -z "$(project_root)" ] ) \
    && ok "skips ISOCLAUDE_HOME (~/.isoclaude) as a project root" \
    || bad "returned global config dir as a project: $(cd "$HOME/child" && project_root)"

#-----------------------------------------------------------------------
section "ensure_iso_home (dev-mode seeding)"

rm -rf "$ISOCLAUDE_HOME"
ensure_iso_home
[ -f "$ISOCLAUDE_HOME/Dockerfile.base" ] \
    && ok "seeded Dockerfile.base from repo" \
    || bad "seed Dockerfile.base"
[ -f "$ISOCLAUDE_HOME/entrypoint.sh" ] \
    && ok "seeded entrypoint.sh from repo" \
    || bad "seed entrypoint.sh"
# Re-run is a no-op (idempotent).
ts="$(stat -f %m "$ISOCLAUDE_HOME/Dockerfile.base" 2>/dev/null || stat -c %Y "$ISOCLAUDE_HOME/Dockerfile.base")"
sleep 1
ensure_iso_home
ts2="$(stat -f %m "$ISOCLAUDE_HOME/Dockerfile.base" 2>/dev/null || stat -c %Y "$ISOCLAUDE_HOME/Dockerfile.base")"
[ "$ts" = "$ts2" ] && ok "ensure_iso_home is idempotent" || bad "re-seeded on second call"

#-----------------------------------------------------------------------
section "read_pin"

# No pin anywhere → should query npm. Since we don't want a network call
# in tests, seed a global pin first.
rm -f "$ISOCLAUDE_HOME/claude-version"
echo "1.2.3" > "$ISOCLAUDE_HOME/claude-version"
got="$(cd "$TMP"; read_pin)"
[ "$got" = "1.2.3" ] && ok "reads global pin" || bad "global pin" "got '$got'"

# Project pin overrides global pin.
echo "9.9.9" > "$TMP/proj/.isoclaude/claude-version"
got="$(cd "$TMP/proj/sub/deeper"; read_pin)"
[ "$got" = "9.9.9" ] && ok "project pin overrides global" || bad "project override" "got '$got'"

# Whitespace tolerance.
printf '  4.5.6\n\n' > "$TMP/proj/.isoclaude/claude-version"
got="$(cd "$TMP/proj"; read_pin)"
[ "$got" = "4.5.6" ] && ok "trims whitespace in pin file" || bad "trim" "got '$got'"

# Empty pin file errors out.
: > "$TMP/proj/.isoclaude/claude-version"
if got="$(cd "$TMP/proj"; read_pin 2>&1)"; then
    bad "errors on empty pin" "got '$got'"
else
    ok "errors on empty pin file"
fi
rm "$TMP/proj/.isoclaude/claude-version"

#-----------------------------------------------------------------------
section "image_label_version"

unset FAKE_LABEL
got="$(image_label_version docker)"
[ -z "$got" ] && ok "returns empty when image is missing" || bad "missing-image" "got '$got'"

FAKE_LABEL="1.2.3" got="$(FAKE_LABEL=1.2.3 image_label_version docker)"
[ "$got" = "1.2.3" ] && ok "returns label when present" || bad "label-present" "got '$got'"

#-----------------------------------------------------------------------
section "ensure_base_image (no-op when label matches)"

: > "$FAKE_DOCKER_LOG"
FAKE_LABEL="1.2.3" ensure_base_image docker "1.2.3"
if grep -q '^build' "$FAKE_DOCKER_LOG"; then
    bad "ensure_base_image rebuilt despite matching label"
else
    ok "no rebuild when label matches target"
fi

: > "$FAKE_DOCKER_LOG"
FAKE_LABEL="1.2.3" ensure_base_image docker "9.9.9"
if grep -q 'build .*CLAUDE_VERSION=9.9.9' "$FAKE_DOCKER_LOG"; then
    ok "rebuilds when label != target with correct build-arg"
else
    bad "ensure_base_image" "log was: $(cat "$FAKE_DOCKER_LOG")"
fi

: > "$FAKE_DOCKER_LOG"
unset FAKE_LABEL
ensure_base_image docker "9.9.9"
if grep -q 'build .*CLAUDE_VERSION=9.9.9' "$FAKE_DOCKER_LOG"; then
    ok "builds on first run (no existing image)"
else
    bad "first-build" "log was: $(cat "$FAKE_DOCKER_LOG")"
fi

#-----------------------------------------------------------------------
section "compose_run_flags"

cd "$TMP/proj"
compose_run_flags
flags="${RUN_FLAGS[*]}"

case "$flags" in
    *"--rm"*) ok "passes --rm" ;;
    *) bad "missing --rm" "flags: $flags" ;;
esac
# -i is always added (so piped stdin gets forwarded). -t is gated on
# stdout being a real TTY (Apple container errors with ENODEV if -t is
# requested without one).
case "$flags" in
    *" -i "*|*" -i") ok "always passes -i (so piped stdin reaches the container)" ;;
    *) bad "missing -i" "flags: $flags" ;;
esac
if [ -t 1 ]; then
    case "$flags" in
        *" -t "*|*" -t") ok "adds -t when stdout is a TTY" ;;
        *) bad "missing -t with TTY stdout" "flags: $flags" ;;
    esac
else
    case "$flags" in
        *" -t "*|*" -t") bad "adds -t without a TTY" "flags: $flags" ;;
        *) ok "omits -t when no TTY stdout (Apple container safe)" ;;
    esac
fi
case "$flags" in
    *"-v $PWD:$PWD"*) ok "mounts \$PWD at same path" ;;
    *) bad "missing \$PWD mount" "flags: $flags" ;;
esac
case "$flags" in
    *"-w $PWD"*) ok "sets workdir to \$PWD" ;;
    *) bad "missing -w" "flags: $flags" ;;
esac
case "$flags" in
    *"-v $HOME/.claude:/home/claude/.claude"*) ok "mounts ~/.claude rw" ;;
    *) bad "missing ~/.claude mount" "flags: $flags" ;;
esac
case "$flags" in
    *"-v $HOME/.claude.json:/home/claude/.claude.json"*) ok "mounts ~/.claude.json rw" ;;
    *) bad "missing ~/.claude.json mount" "flags: $flags" ;;
esac
case "$flags" in
    *":/home/claude/.gitconfig:ro"*) ok "mounts ~/.gitconfig ro" ;;
    *) bad "missing ~/.gitconfig mount" "flags: $flags" ;;
esac
case "$flags" in
    *":/home/claude/.ssh:ro"*) ok "mounts ~/.ssh ro" ;;
    *) bad "missing ~/.ssh mount" "flags: $flags" ;;
esac
case "$flags" in
    *"-e HOST_UID=$(id -u)"*) ok "passes HOST_UID" ;;
    *) bad "missing HOST_UID env" ;;
esac
case "$flags" in
    *"-e HOST_GID=$(id -g)"*) ok "passes HOST_GID" ;;
    *) bad "missing HOST_GID env" ;;
esac
case "$flags" in
    *"-e TERM -e COLORTERM"*) ok "forwards TERM and COLORTERM" ;;
    *) bad "missing terminal env" "flags: $flags" ;;
esac

# Missing host files → wrapper should warn, not crash.
rm -f "$HOME/.gitconfig" "$HOME/.claude.json"
rm -rf "$HOME/.ssh"
compose_run_flags 2>/dev/null
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *".gitconfig"*) bad "should skip missing gitconfig" ;;
    *) ok "skips ~/.gitconfig mount when host file missing" ;;
esac
case "$flags" in
    *".ssh"*) bad "should skip missing .ssh" ;;
    *) ok "skips ~/.ssh mount when host dir missing" ;;
esac
case "$flags" in
    *".claude.json"*) bad "should skip missing ~/.claude.json" ;;
    *) ok "skips ~/.claude.json mount when host file missing" ;;
esac
mkdir -p "$HOME/.ssh"; echo k > "$HOME/.ssh/id_ed25519"
echo "[user]" > "$HOME/.gitconfig"
echo '{}' > "$HOME/.claude.json"

#-----------------------------------------------------------------------
section "_exec_in_sandbox with ISOCLAUDE_DRY_RUN"

cd "$TMP/proj"
ISOCLAUDE_DRY_RUN=1 out="$(_exec_in_sandbox docker claude --foo --bar)"
case "$out" in
    "docker run "*) ok "dry-run starts with 'docker run'" ;;
    *) bad "dry-run prefix" "got: $out" ;;
esac
case "$out" in
    *isoclaude-base:test*) ok "dry-run names the configured image" ;;
    *) bad "dry-run image" "got: $out" ;;
esac
case "$out" in
    *claude*--foo*--bar*) ok "dry-run appends user args after the entry" ;;
    *) bad "dry-run args" "got: $out" ;;
esac

# Same machinery should be able to run a different entry command (used by cmd_shell).
ISOCLAUDE_DRY_RUN=1 out="$(_exec_in_sandbox docker bash -l)"
case "$out" in
    *isoclaude-base:test\ bash\ -l) ok "dry-run honors a non-claude entry (bash -l)" ;;
    *) bad "alternate entry" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "End-to-end main() with mocks"

# Reset state for an end-to-end pass.
rm -rf "$ISOCLAUDE_HOME"
mkdir -p "$ISOCLAUDE_HOME"
echo "5.5.5" > "$ISOCLAUDE_HOME/claude-version"
: > "$FAKE_DOCKER_LOG"
unset FAKE_LABEL

cd "$TMP/proj"
# Run wrapper as a subprocess (not sourced) so main() executes.
out="$(ISOCLAUDE_DRY_RUN=1 \
       ISOCLAUDE_HOME="$ISOCLAUDE_HOME" \
       ISOCLAUDE_RUNTIME=docker \
       ISOCLAUDE_BASE_IMAGE="$ISOCLAUDE_BASE_IMAGE" \
       PATH="$PATH" HOME="$HOME" \
       FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
       "$WRAPPER" hello world 2>/dev/null)"
case "$out" in
    "docker run "*claude*hello*world*) ok "main() composes correct dry-run output" ;;
    *) bad "end-to-end dry-run" "got: $out" ;;
esac
if grep -q 'build .*CLAUDE_VERSION=5.5.5' "$FAKE_DOCKER_LOG"; then
    ok "main() triggers base image build at pinned version"
else
    bad "end-to-end build" "log: $(cat "$FAKE_DOCKER_LOG")"
fi

#-----------------------------------------------------------------------
printf '\n\033[1mPhase 2: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
