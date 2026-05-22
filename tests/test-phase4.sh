#!/usr/bin/env bash
# Phase 4 tests: project config plumbing.
#
# Covers: env-file wiring, mounts-file parsing (~ expansion, comments,
# blanks, invalid lines), local/ overrides, project Dockerfile FROM
# validation, and tag-by-hash for the project image.

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

# Fake runtime that logs argv and "succeeds" at build/inspect-by-existence.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_DOCKER_LOG"
case "$1" in
    image)
        if [ "$2" = "inspect" ]; then
            # If FAKE_LABEL is set, return label JSON. If FAKE_IMAGE_EXISTS
            # contains the target image, succeed silently. Otherwise exit 1.
            target="$3"
            if [ -n "${FAKE_LABEL:-}" ] && [ "$target" = "isoclaude-base:test" ]; then
                printf '[{"Config":{"Labels":{"isoclaude.claude_version":"%s"}}}]\n' "$FAKE_LABEL"
                exit 0
            fi
            for existing in ${FAKE_IMAGE_EXISTS:-}; do
                [ "$existing" = "$target" ] && exit 0
            done
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

export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
echo "[user]" > "$HOME/.gitconfig"
mkdir -p "$HOME/.ssh"; echo k > "$HOME/.ssh/id_ed25519"

export ISOCLAUDE_HOME="$HOME/.isoclaude"
export ISOCLAUDE_RUNTIME="docker"
export ISOCLAUDE_BASE_IMAGE="isoclaude-base:test"
export PATH="$TMP/fakebin:$PATH"
export FAKE_DOCKER_LOG="$TMP/docker.log"

# shellcheck disable=SC1090
. "$WRAPPER"
ok "wrapper sourced"

reset_proj() {
    rm -rf "$ISOCLAUDE_HOME" "$TMP/proj"
    mkdir -p "$ISOCLAUDE_HOME" "$TMP/proj/.isoclaude/local"
    cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
    cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
    echo "1.2.3" > "$ISOCLAUDE_HOME/claude-version"
    : > "$FAKE_DOCKER_LOG"
    unset FAKE_LABEL FAKE_IMAGE_EXISTS
    cd "$TMP/proj"
    # Reset state Phase 4 cares about.
    PROJECT_ROOT="$(project_root)"
    RUN_IMAGE="$ISOCLAUDE_BASE_IMAGE"
}

#-----------------------------------------------------------------------
section "env files: wiring + local override + malformed-line tolerance"

reset_proj
echo 'FOO=bar' > "$TMP/proj/.isoclaude/env"
compose_run_flags
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"-e FOO=bar"*) ok "adds -e KEY=VALUE for committed env" ;;
    *) bad "committed env missing" "flags: $flags" ;;
esac

echo 'FOO=overridden' > "$TMP/proj/.isoclaude/local/env"
compose_run_flags
flags="${RUN_FLAGS[*]}"
# Committed must come before local (later -e wins in docker).
committed_pos=${flags%%"-e FOO=bar"*}
local_pos=${flags%%"-e FOO=overridden"*}
if [ ${#committed_pos} -lt ${#local_pos} ]; then
    ok "local/env -e flags follow committed -e (so local wins)"
else
    bad "ordering" "committed pos=${#committed_pos}, local pos=${#local_pos}"
fi

# Missing env file: no env -e additions.
rm "$TMP/proj/.isoclaude/env" "$TMP/proj/.isoclaude/local/env"
compose_run_flags
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"-e FOO=bar"*|*"-e FOO=overridden"*) bad "leftover env -e" "flags: $flags" ;;
    *) ok "no project env -e when no env files" ;;
esac

# Malformed env file: must NOT crash the wrapper and must NOT pass bad
# lines to the runtime (Apple container rejects them and fails the run).
cat > "$TMP/proj/.isoclaude/env" <<'EOF'
# A comment
GOOD=ok
this-line-has-no-equals
=empty-key-value
ANOTHER=also-ok
EOF
# Capture stderr to a file (warnings) but let compose_run_flags run in the
# parent shell so RUN_FLAGS mutations propagate.
compose_run_flags 2>"$TMP/cf.err"
flags="${RUN_FLAGS[*]}"
out=$(cat "$TMP/cf.err")
case "$flags" in
    *"-e GOOD=ok"*"-e ANOTHER=also-ok"*) ok "keeps valid env lines from a mixed file" ;;
    *) bad "valid lines dropped" "flags: $flags" ;;
esac
case "$flags" in
    *"this-line-has-no-equals"*|*"=empty-key-value"*) bad "bad lines reached the runtime" "flags: $flags" ;;
    *) ok "skips malformed env lines" ;;
esac
case "$out" in
    *"skipping line without '='"*"this-line-has-no-equals"*) ok "warns on no-equals line" ;;
    *) bad "no warning for missing =" "got: $out" ;;
esac
case "$out" in
    *"skipping line with empty key"*"=empty-key-value"*) ok "warns on empty-key line" ;;
    *) bad "no warning for empty key" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "mounts file: parsing + ~ expansion"

reset_proj
# Pre-create the host paths the test references — the wrapper now refuses
# mounts whose host path doesn't exist (Apple container would otherwise
# error with a cryptic "path does not exist" message).
mkdir -p "$TMP/host-tmp-foo" "$HOME/scratch" "$TMP/host-abs"
cat > "$TMP/proj/.isoclaude/mounts" <<EOF
# A comment line that should be ignored.

$TMP/host-tmp-foo:/work/foo
~/scratch:/scratch:ro
   # leading-space comment
$TMP/host-abs:/dst
EOF
compose_run_flags
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"-v $TMP/host-tmp-foo:/work/foo"*)   ok "mounts absolute host path"        ;;
    *) bad "absolute mount missing" "flags: $flags" ;;
esac
case "$flags" in
    *"-v $HOME/scratch:/scratch:ro"*)     ok "expands leading ~ in host path"   ;;
    *) bad "~ expansion failed" "flags: $flags" ;;
esac
case "$flags" in
    *"-v $TMP/host-abs:/dst"*)            ok "handles multiple mounts"          ;;
    *) bad "second absolute mount missing" "flags: $flags" ;;
esac
# Comments shouldn't appear as flags.
case "$flags" in
    *"-v # "*|*"# A comment"*) bad "comment leaked into mount flags" ;;
    *) ok "skips comment lines and blanks" ;;
esac

# Mount with a host path that doesn't exist → warn and skip (instead of
# letting the runtime error out with a cryptic message).
echo "/nonexistent-host-path/oops:/inside:ro" > "$TMP/proj/.isoclaude/mounts"
compose_run_flags 2>"$TMP/cf.err"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *nonexistent-host-path*) bad "missing host path leaked into flags" ;;
    *) ok "skips mount when host path is absent" ;;
esac
out=$(cat "$TMP/cf.err")
case "$out" in
    *"host path doesn't exist"*nonexistent*) ok "warns when skipping missing-host-path mount" ;;
    *) bad "no warning" "got: $out" ;;
esac

# Invalid mount line (no colon) → warn, skip.
echo "no-colon-here" > "$TMP/proj/.isoclaude/mounts"
out=$(compose_run_flags 2>&1)
flags="${RUN_FLAGS[*]}"
case "$out" in
    *"skipping invalid mount line"*"no-colon-here"*) ok "warns on invalid mount line" ;;
    *) bad "no warning" "out: $out" ;;
esac
case "$flags" in
    *no-colon-here*) bad "invalid mount line leaked into flags" ;;
    *) ok "invalid lines don't reach the runtime" ;;
esac

# local/mounts also read.
rm "$TMP/proj/.isoclaude/mounts"
mkdir -p "$TMP/host-local-only"
cat > "$TMP/proj/.isoclaude/local/mounts" <<EOF
$TMP/host-local-only:/local-only:ro
EOF
compose_run_flags
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"-v $TMP/host-local-only:/local-only:ro"*) ok "reads local/mounts" ;;
    *) bad "local/mounts not read" "flags: $flags" ;;
esac

#-----------------------------------------------------------------------
section "ensure_project_image: gating + validation"

reset_proj

# No Dockerfile -> no-op, RUN_IMAGE unchanged.
RUN_IMAGE="$ISOCLAUDE_BASE_IMAGE"
ensure_project_image docker "$TMP/proj"
[ "$RUN_IMAGE" = "$ISOCLAUDE_BASE_IMAGE" ] && ok "no Dockerfile -> RUN_IMAGE stays at base" \
    || bad "RUN_IMAGE changed: $RUN_IMAGE"

# Dockerfile present but no FROM -> still a no-op (init scaffold case).
echo "# all comments" > "$TMP/proj/.isoclaude/Dockerfile"
RUN_IMAGE="$ISOCLAUDE_BASE_IMAGE"
ensure_project_image docker "$TMP/proj"
[ "$RUN_IMAGE" = "$ISOCLAUDE_BASE_IMAGE" ] && ok "no FROM -> still no-op" \
    || bad "scaffold Dockerfile triggered build"

# Wrong FROM -> die.
cat > "$TMP/proj/.isoclaude/Dockerfile" <<'EOF'
FROM alpine:3
RUN echo nope
EOF
if (RUN_IMAGE="$ISOCLAUDE_BASE_IMAGE"; ensure_project_image docker "$TMP/proj" 2>/dev/null); then
    bad "wrong FROM should error"
else
    ok "wrong FROM is rejected"
fi

# Correct FROM -> builds, sets RUN_IMAGE to a project tag.
cat > "$TMP/proj/.isoclaude/Dockerfile" <<'EOF'
FROM isoclaude-base:latest
RUN echo ok
EOF
: > "$FAKE_DOCKER_LOG"
RUN_IMAGE="$ISOCLAUDE_BASE_IMAGE"
ensure_project_image docker "$TMP/proj"
case "$RUN_IMAGE" in
    isoclaude-project-*:latest) ok "RUN_IMAGE set to project tag" ;;
    *) bad "RUN_IMAGE wrong" "got: $RUN_IMAGE" ;;
esac
grep -q 'build .*-t isoclaude-project-' "$FAKE_DOCKER_LOG" \
    && ok "build invoked for project image" || bad "no project build call"

# Same Dockerfile content -> same tag -> no rebuild on second call.
expected_tag="$RUN_IMAGE"
: > "$FAKE_DOCKER_LOG"
export FAKE_IMAGE_EXISTS="$expected_tag"
RUN_IMAGE="$ISOCLAUDE_BASE_IMAGE"
ensure_project_image docker "$TMP/proj"
[ "$RUN_IMAGE" = "$expected_tag" ] && ok "reuses same tag when content unchanged" || bad "tag changed"
grep -q '^build' "$FAKE_DOCKER_LOG" && bad "rebuild despite cached image" || ok "skips build when image already exists"
unset FAKE_IMAGE_EXISTS

# Change Dockerfile -> new hash -> new tag.
echo "# tweak" >> "$TMP/proj/.isoclaude/Dockerfile"
RUN_IMAGE="$ISOCLAUDE_BASE_IMAGE"
ensure_project_image docker "$TMP/proj"
[ "$RUN_IMAGE" != "$expected_tag" ] && ok "different content -> different tag" \
    || bad "tag should have changed"

#-----------------------------------------------------------------------
section "_exec_in_sandbox uses RUN_IMAGE"

reset_proj
cat > "$TMP/proj/.isoclaude/Dockerfile" <<'EOF'
FROM isoclaude-base:latest
EOF
ensure_project_image docker "$TMP/proj"
ISOCLAUDE_DRY_RUN=1 out=$(ISOCLAUDE_DRY_RUN=1 _exec_in_sandbox docker claude --foo 2>&1)
case "$out" in
    *isoclaude-project-*\ claude\ --foo) ok "_exec_in_sandbox runs the project image, not base" ;;
    *) bad "wrong image in run command" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "End-to-end: all four overlays integrated"

reset_proj
mkdir -p "$TMP/host-data" "$HOME/.cache/foo"
echo 'PROJ_VAR=set' > "$TMP/proj/.isoclaude/env"
echo 'LOCAL_VAR=set' > "$TMP/proj/.isoclaude/local/env"
echo "$TMP/host-data:/data:ro" > "$TMP/proj/.isoclaude/mounts"
echo '~/.cache/foo:/home/claude/.cache/foo' > "$TMP/proj/.isoclaude/local/mounts"
cat > "$TMP/proj/.isoclaude/Dockerfile" <<'EOF'
FROM isoclaude-base:latest
RUN echo project-layer
EOF

# End-to-end run through the dispatcher.
: > "$FAKE_DOCKER_LOG"
out=$(cd "$TMP/proj" && \
      ISOCLAUDE_HOME="$ISOCLAUDE_HOME" \
      ISOCLAUDE_RUNTIME=docker \
      ISOCLAUDE_BASE_IMAGE="$ISOCLAUDE_BASE_IMAGE" \
      ISOCLAUDE_DRY_RUN=1 \
      PATH="$PATH" HOME="$HOME" \
      FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
      "$WRAPPER" --some-claude-flag 2>&1 | tail -1)

case "$out" in
    *"-e PROJ_VAR=set"*"-e LOCAL_VAR=set"*) ok "both env files reach docker as -e flags, in order" ;;
    *) bad "env -e flags missing or out of order" "got: $out" ;;
esac
case "$out" in
    *-v\ "$TMP"/host-data:/data:ro*) ok "committed mount in run command" ;;
    *) bad "mount missing" "got: $out" ;;
esac
case "$out" in
    *-v\ $HOME/.cache/foo:/home/claude/.cache/foo*) ok "local mount with ~ expansion in run command" ;;
    *) bad "local mount missing" ;;
esac
case "$out" in
    *isoclaude-project-*\ claude\ --some-claude-flag) ok "project image, not base, is used at runtime" ;;
    *) bad "project image not selected" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "cmd_version reports project image"

reset_proj
cat > "$TMP/proj/.isoclaude/Dockerfile" <<'EOF'
FROM isoclaude-base:latest
EOF
out=$(cd "$TMP/proj" && cmd_version 2>&1)
case "$out" in
    *"project image: isoclaude-project-"*"(built: no)"*) ok "version shows unbuilt project image tag" ;;
    *) bad "project image info" "got: $out" ;;
esac

# Pretend the project image is built.
hash=$(_file_hash "$TMP/proj/.isoclaude/Dockerfile")
FAKE_IMAGE_EXISTS="isoclaude-project-${hash}:latest"
out=$(cd "$TMP/proj" && FAKE_IMAGE_EXISTS="$FAKE_IMAGE_EXISTS" cmd_version 2>&1)
case "$out" in
    *"project image: isoclaude-project-${hash}:latest (built: yes)"*) ok "version shows built status" ;;
    *) bad "built status" "got: $out" ;;
esac

#-----------------------------------------------------------------------
printf '\n\033[1mPhase 4: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
