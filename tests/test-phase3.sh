#!/usr/bin/env bash
# Phase 3 tests: dispatcher + subcommands.
#
# Sources the wrapper and runs each cmd_X against a tmp HOME + mocked
# docker and npm. The "End-to-end" section runs the wrapper as a
# subprocess so the dispatcher is exercised for real.

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO/bin/isoclaude"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

#-----------------------------------------------------------------------
section "Test harness"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake docker — same shape as the Phase 2 mock.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_DOCKER_LOG"
case "$1" in
    image)
        if [ "$2" = "inspect" ]; then
            if [ -n "${FAKE_LABEL:-}" ]; then
                printf '[{"Config":{"Labels":{"isoclaude.claude_version":"%s"}}}]\n' "$FAKE_LABEL"
                exit 0
            fi
            exit 1
        fi
        if [ "$2" = "rm" ]; then exit 0; fi
        ;;
    build) exit 0 ;;
    run)   exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/fakebin/docker"

# Fake npm — returns NPM_FAKE_VERSION when called as `npm view ... version`.
cat > "$TMP/fakebin/npm" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_NPM_LOG"
if [ "$1" = "view" ] && [ "$3" = "version" ]; then
    printf '%s\n' "${NPM_FAKE_VERSION:-9.9.9}"
fi
exit 0
EOF
chmod +x "$TMP/fakebin/npm"

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$HOME/.ssh"
echo "[user]" > "$HOME/.gitconfig"
echo "k" > "$HOME/.ssh/id_ed25519"

export ISOCLAUDE_HOME="$HOME/.isoclaude"
export ISOCLAUDE_RUNTIME="docker"
export ISOCLAUDE_BASE_IMAGE="isoclaude-base:test"
export PATH="$TMP/fakebin:$PATH"
export FAKE_DOCKER_LOG="$TMP/docker.log"
export FAKE_NPM_LOG="$TMP/npm.log"

# shellcheck disable=SC1090
. "$WRAPPER"
ok "wrapper sourced"

# Helper: reset all mutable test state between subcommand tests.
reset() {
    rm -rf "$ISOCLAUDE_HOME" "$TMP/proj"
    mkdir -p "$ISOCLAUDE_HOME" "$TMP/proj"
    cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
    cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
    echo "1.2.3" > "$ISOCLAUDE_HOME/claude-version"
    : > "$FAKE_DOCKER_LOG"
    : > "$FAKE_NPM_LOG"
    unset FAKE_LABEL
    cd "$TMP/proj"
}

#-----------------------------------------------------------------------
section "cmd_help"

out=$(cmd_help)
case "$out" in
    *"isoclaude"*"SUBCOMMANDS"*) ok "cmd_help prints usage" ;;
    *) bad "cmd_help" "got: $out" ;;
esac
for sub in run shell init build version update pin; do
    case "$out" in
        *" $sub "*) ok "help mentions '$sub'" ;;
        *) bad "help missing '$sub'" ;;
    esac
done

#-----------------------------------------------------------------------
section "cmd_init"

reset
cmd_init >/dev/null 2>&1
[ -f "$TMP/proj/.isoclaude/Dockerfile" ] && ok "creates Dockerfile" || bad "no Dockerfile"
[ -f "$TMP/proj/.isoclaude/env"        ] && ok "creates env"        || bad "no env"
[ -f "$TMP/proj/.isoclaude/mounts"     ] && ok "creates mounts"     || bad "no mounts"
[ -f "$TMP/proj/.isoclaude/.gitignore" ] && ok "creates .gitignore" || bad "no .gitignore"
[ -d "$TMP/proj/.isoclaude/local"      ] && ok "creates local/"     || bad "no local/"

grep -q '^local/' "$TMP/proj/.isoclaude/.gitignore" \
    && ok ".gitignore excludes local/" || bad ".gitignore content"

# Templates should be commented-out so the scaffold is a no-op until edited.
grep -q '^# *FROM isoclaude-base' "$TMP/proj/.isoclaude/Dockerfile" \
    && ok "Dockerfile template is commented out by default" || bad "Dockerfile not commented"

# Idempotency: re-running shouldn't overwrite (we tweak Dockerfile then re-init).
echo "MARKER" > "$TMP/proj/.isoclaude/Dockerfile"
cmd_init >/dev/null 2>&1
if grep -q '^MARKER$' "$TMP/proj/.isoclaude/Dockerfile"; then
    ok "re-running cmd_init does not overwrite existing files"
else
    bad "cmd_init overwrote existing Dockerfile"
fi

# A re-run should also work if only some files are missing.
rm "$TMP/proj/.isoclaude/env"
cmd_init >/dev/null 2>&1
[ -f "$TMP/proj/.isoclaude/env" ] && ok "re-run creates only the missing files" || bad "env not re-created"
grep -q '^MARKER$' "$TMP/proj/.isoclaude/Dockerfile" && ok "still preserves existing files" || bad "preservation broken"

#-----------------------------------------------------------------------
section "cmd_version"

reset
# Fresh state: global pin only.
out=$(cmd_version 2>&1)
case "$out" in
    *"global pin:"*"1.2.3"*) ok "shows global pin" ;;
    *) bad "global pin output" "got: $out" ;;
esac
case "$out" in
    *"project pin:"*"<unset>"*) ok "shows <unset> when no project pin" ;;
    *) bad "project pin output" "got: $out" ;;
esac
case "$out" in
    *"image label:"*"<not built>"*) ok "shows <not built> when image missing" ;;
    *) bad "image label output" "got: $out" ;;
esac

# With a project pin and a built image.
mkdir -p "$TMP/proj/.isoclaude"
echo "7.7.7" > "$TMP/proj/.isoclaude/claude-version"
FAKE_LABEL="1.2.3"
out=$(FAKE_LABEL="1.2.3" cmd_version 2>&1)
case "$out" in
    *"project pin:"*"7.7.7"*)   ok "shows project pin when set" ;;
    *) bad "project pin shown" "got: $out" ;;
esac
case "$out" in
    *"image label:"*"1.2.3"*)   ok "shows image label when image exists" ;;
    *) bad "image label shown" "got: $out" ;;
esac
case "$out" in
    *"project root:"*"$TMP/proj"*) ok "shows project root path" ;;
    *) bad "project root shown" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "cmd_update"

reset
# `update --check` should make exactly one npm call and not modify state.
NPM_FAKE_VERSION="9.9.9" out=$(NPM_FAKE_VERSION="9.9.9" cmd_update --check 2>&1)
case "$out" in
    *"current global pin:"*"1.2.3"*"latest on npm:"*"9.9.9"*) ok "--check shows current vs latest" ;;
    *) bad "--check output" "got: $out" ;;
esac
npm_calls=$(wc -l < "$FAKE_NPM_LOG")
[ "$npm_calls" -eq 1 ] && ok "--check makes exactly one npm call" || bad "$npm_calls npm calls (expected 1)"
pin_after=$(cat "$ISOCLAUDE_HOME/claude-version")
[ "$pin_after" = "1.2.3" ] && ok "--check does not modify the pin" || bad "pin was modified to '$pin_after'"

# `update` with an explicit version writes the pin, rebuilds, no npm call.
: > "$FAKE_NPM_LOG"; : > "$FAKE_DOCKER_LOG"
cmd_update 5.5.5 >/dev/null 2>&1
[ "$(cat "$ISOCLAUDE_HOME/claude-version")" = "5.5.5" ] \
    && ok "update VERSION writes the pin" || bad "pin not written"
[ ! -s "$FAKE_NPM_LOG" ] && ok "explicit version skips npm" || bad "made npm call: $(cat "$FAKE_NPM_LOG")"
grep -q 'build .*CLAUDE_VERSION=5.5.5' "$FAKE_DOCKER_LOG" \
    && ok "update triggers rebuild at new version" || bad "no rebuild log"

# `update` with no arg → query npm for latest.
: > "$FAKE_NPM_LOG"; : > "$FAKE_DOCKER_LOG"
NPM_FAKE_VERSION="8.8.8" cmd_update >/dev/null 2>&1
[ "$(cat "$ISOCLAUDE_HOME/claude-version")" = "8.8.8" ] \
    && ok "update with no arg picks up npm latest" || bad "pin = $(cat "$ISOCLAUDE_HOME/claude-version")"

#-----------------------------------------------------------------------
section "cmd_pin"

reset
# No .isoclaude/ in PWD → cmd_pin should create one.
[ ! -d "$TMP/proj/.isoclaude" ] || rm -rf "$TMP/proj/.isoclaude"
cmd_pin 6.6.6 >/dev/null 2>&1
[ -f "$TMP/proj/.isoclaude/claude-version" ] \
    && ok "cmd_pin creates .isoclaude/ on first call" || bad "no .isoclaude/ created"
[ "$(cat "$TMP/proj/.isoclaude/claude-version")" = "6.6.6" ] \
    && ok "cmd_pin writes the requested version" || bad "wrong version pinned"

# Pin with no arg should default to current global pin.
rm -rf "$TMP/proj/.isoclaude"
cmd_pin >/dev/null 2>&1
[ "$(cat "$TMP/proj/.isoclaude/claude-version")" = "1.2.3" ] \
    && ok "cmd_pin with no arg uses current global pin" || bad "didn't use global"

# Subdir → walks up to the project root, doesn't create a nested one.
mkdir -p "$TMP/proj/sub/sub2"
( cd "$TMP/proj/sub/sub2" && cmd_pin 4.4.4 >/dev/null 2>&1 )
[ "$(cat "$TMP/proj/.isoclaude/claude-version")" = "4.4.4" ] \
    && ok "cmd_pin from subdir writes to the project root" || bad "wrote elsewhere"
[ ! -d "$TMP/proj/sub/sub2/.isoclaude" ] \
    && ok "cmd_pin doesn't create nested .isoclaude/" || bad "nested .isoclaude/ created"

# Pin with no arg AND no global pin → error.
reset
rm "$ISOCLAUDE_HOME/claude-version"
rm -rf "$TMP/proj/.isoclaude"
if out=$(cmd_pin 2>&1); then
    bad "cmd_pin with no arg + no global should error" "got: $out"
else
    ok "cmd_pin errors when no version and no global pin"
fi

#-----------------------------------------------------------------------
section "cmd_build"

reset
FAKE_LABEL="1.2.3"
: > "$FAKE_DOCKER_LOG"
cmd_build >/dev/null 2>&1
grep -q 'image rm' "$FAKE_DOCKER_LOG"  && ok "cmd_build removes existing image first" || bad "no image rm"
grep -q 'build .*CLAUDE_VERSION=1.2.3' "$FAKE_DOCKER_LOG" \
    && ok "cmd_build invokes build with current pin" || bad "no build call"

#-----------------------------------------------------------------------
section "cmd_run and cmd_shell"

reset
ISOCLAUDE_DRY_RUN=1 out=$(cd "$TMP/proj" && ISOCLAUDE_DRY_RUN=1 cmd_run --foo 2>&1)
case "$out" in
    *isoclaude-base:test*claude*--foo*) ok "cmd_run dry-runs claude with args" ;;
    *) bad "cmd_run dry-run" "got: $out" ;;
esac

ISOCLAUDE_DRY_RUN=1 out=$(cd "$TMP/proj" && ISOCLAUDE_DRY_RUN=1 cmd_shell 2>&1)
case "$out" in
    *isoclaude-base:test\ bash) ok "cmd_shell dry-runs bash (no args)" ;;
    *) bad "cmd_shell dry-run" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "Dispatcher routing (subprocess)"

# Run wrapper as a subprocess for each branch. The harness vars propagate.
RUN_WRAPPER() {
    ISOCLAUDE_HOME="$ISOCLAUDE_HOME" \
    ISOCLAUDE_RUNTIME=docker \
    ISOCLAUDE_BASE_IMAGE="$ISOCLAUDE_BASE_IMAGE" \
    ISOCLAUDE_DRY_RUN=1 \
    PATH="$PATH" HOME="$HOME" \
    FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
    FAKE_NPM_LOG="$FAKE_NPM_LOG" \
    "$WRAPPER" "$@"
}

reset

# `help` subcommand
out=$(RUN_WRAPPER help 2>&1)
case "$out" in *SUBCOMMANDS*) ok "dispatcher routes 'help'" ;; *) bad "help routing" "got: $out" ;; esac

# `--help` flag
out=$(RUN_WRAPPER --help 2>&1)
case "$out" in *SUBCOMMANDS*) ok "dispatcher routes '--help'" ;; *) bad "--help routing" ;; esac

# no args -> cmd_run (claude)
out=$(cd "$TMP/proj" && RUN_WRAPPER 2>&1)
case "$out" in *claude*) ok "no args dispatches to cmd_run" ;; *) bad "default routing" "got: $out" ;; esac

# explicit `run` subcommand
out=$(cd "$TMP/proj" && RUN_WRAPPER run --my-arg 2>&1)
case "$out" in *claude*--my-arg*) ok "'run' routes to claude with args" ;; *) bad "run routing" "got: $out" ;; esac

# `shell`
out=$(cd "$TMP/proj" && RUN_WRAPPER shell 2>&1)
case "$out" in *isoclaude-base:test\ bash*) ok "'shell' routes to bash" ;; *) bad "shell routing" "got: $out" ;; esac

# `--` separator passes everything as claude args
out=$(cd "$TMP/proj" && RUN_WRAPPER -- --some-claude-flag 2>&1)
case "$out" in *claude*--some-claude-flag*) ok "'--' passes everything as claude args" ;; *) bad "-- routing" "got: $out" ;; esac

# Unknown first arg → treat as claude arg
out=$(cd "$TMP/proj" && RUN_WRAPPER --not-a-subcommand 2>&1)
case "$out" in *claude*--not-a-subcommand*) ok "unknown first arg falls through to cmd_run" ;; *) bad "fallthrough routing" "got: $out" ;; esac

# Project pin written by `pin` subcommand should be picked up by next run.
RUN_WRAPPER pin 3.3.3 >/dev/null 2>&1
out=$(cd "$TMP/proj" && RUN_WRAPPER version 2>&1)
case "$out" in
    *"project pin:"*"3.3.3"*) ok "pin -> version round-trips through the dispatcher" ;;
    *) bad "pin/version roundtrip" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "--yolo / -Y / ISOCLAUDE_YOLO -> --dangerously-skip-permissions"

reset

# Bare --yolo with no other args.
out=$(cd "$TMP/proj" && RUN_WRAPPER --yolo 2>&1 | tail -1)
case "$out" in
    *"claude --dangerously-skip-permissions") ok "bare --yolo translates" ;;
    *) bad "bare --yolo" "got: $out" ;;
esac

# --yolo before subcommand
out=$(cd "$TMP/proj" && RUN_WRAPPER --yolo run --foo 2>&1 | tail -1)
case "$out" in
    *"claude --dangerously-skip-permissions --foo") ok "--yolo before subcommand" ;;
    *) bad "--yolo before subcommand" "got: $out" ;;
esac

# --yolo after subcommand
out=$(cd "$TMP/proj" && RUN_WRAPPER run --yolo --foo 2>&1 | tail -1)
case "$out" in
    *"claude --dangerously-skip-permissions --foo") ok "--yolo after subcommand" ;;
    *) bad "--yolo after subcommand" "got: $out" ;;
esac

# -Y short alias.
out=$(cd "$TMP/proj" && RUN_WRAPPER -Y --foo 2>&1 | tail -1)
case "$out" in
    *"claude --dangerously-skip-permissions --foo") ok "-Y short alias works" ;;
    *) bad "-Y" "got: $out" ;;
esac

# ISOCLAUDE_YOLO=1 env var.
out=$(cd "$TMP/proj" && ISOCLAUDE_YOLO=1 RUN_WRAPPER --foo 2>&1 | tail -1)
case "$out" in
    *"claude --dangerously-skip-permissions --foo") ok "ISOCLAUDE_YOLO=1 env var" ;;
    *) bad "env var" "got: $out" ;;
esac

# No yolo (control): no flag added.
out=$(cd "$TMP/proj" && RUN_WRAPPER --foo 2>&1 | tail -1)
case "$out" in
    *"--dangerously-skip-permissions"*) bad "added skip flag without --yolo" ;;
    *"claude --foo") ok "no --yolo means no skip flag" ;;
    *) bad "control case" "got: $out" ;;
esac

# --yolo with `shell` should NOT add the flag (bash doesn't know it).
out=$(cd "$TMP/proj" && RUN_WRAPPER --yolo shell 2>&1 | tail -1)
case "$out" in
    *"--dangerously-skip-permissions"*) bad "--yolo leaked into shell command" ;;
    *bash*) ok "--yolo is ignored by shell subcommand" ;;
    *) bad "shell+yolo" "got: $out" ;;
esac

# --yolo with `init` is a no-op (init doesn't launch a container).
out=$(cd "$TMP/proj/sub" 2>/dev/null || cd "$TMP/proj"; RUN_WRAPPER --yolo init 2>&1; echo "exit:$?")
case "$out" in
    *exit:0*) ok "--yolo + init runs cleanly (yolo is a no-op for non-run subcommands)" ;;
    *) bad "init+yolo" "got: $out" ;;
esac

#-----------------------------------------------------------------------
printf '\n\033[1mPhase 3: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
