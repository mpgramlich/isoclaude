#!/usr/bin/env bash
# Live tests: requires a real container runtime on PATH.
#
# Verifies the things static + mocked tests can't:
#   1. wrapper end-to-end (build + run + claude --version)
#   2. UID/GID remap: files written inside the container are owned by the
#      host user on the host side
#   3. Bind-mount isolation: paths outside the mount list aren't visible
#   4. RO enforcement: writes to read-only mounts fail
#   5. Signal handling: SIGTERM/SIGINT reaches PID 1 through gosu

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO/bin/isoclaude"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Pick the same runtime our wrapper would pick.
runtime=""
for r in container orb docker podman; do
    if command -v "$r" >/dev/null 2>&1; then runtime="$r"; break; fi
done
if [ -z "$runtime" ]; then
    echo "no container runtime on PATH — skipping all live tests"
    exit 0
fi
echo "using runtime: $runtime"

#-----------------------------------------------------------------------
section "Build a live test image (separate tag from production)"

IMG="isoclaude-live-test:latest"
V="2.1.143"
TMP="$(mktemp -d)"
trap '"$runtime" image rm "$IMG" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

set +e
"$runtime" build --build-arg "CLAUDE_VERSION=$V" \
    -t "$IMG" -f "$REPO/image/Dockerfile.base" "$REPO/image" \
    >"$TMP/build.log" 2>&1
build_rc=$?
set -e
if [ "$build_rc" -ne 0 ]; then
    bad "build" "see $TMP/build.log"
    echo "Phase live: 0 passed, 1 failed"; exit 1
fi
ok "image built ($IMG @ $V)"

#-----------------------------------------------------------------------
section "Wrapper end-to-end (Phase 2 live)"

# Isolate ISOCLAUDE_HOME so we don't touch the user's real ~/.isoclaude/.
# Pre-seed the pin so the wrapper doesn't make an npm call.
ISO_HOME="$TMP/iso"
mkdir -p "$ISO_HOME"
cp "$REPO/image/Dockerfile.base" "$ISO_HOME/Dockerfile.base"
cp "$REPO/image/entrypoint.sh"   "$ISO_HOME/entrypoint.sh"
echo "$V" > "$ISO_HOME/claude-version"

# Use a distinct image tag so we don't collide with the user's real image.
WRAPPER_IMG="isoclaude-live-wrapper:latest"
trap '"$runtime" image rm "$IMG" "$WRAPPER_IMG" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# Run wrapper. -it would fail without a TTY in some CI contexts; here we
# inherit the terminal from this shell, which works in interactive sessions.
# claude --version exits immediately so TTY handling isn't critical.
mkdir -p "$TMP/proj"
set +e
out=$(cd "$TMP/proj" && \
      ISOCLAUDE_HOME="$ISO_HOME" \
      ISOCLAUDE_BASE_IMAGE="$WRAPPER_IMG" \
      ISOCLAUDE_RUNTIME="$runtime" \
      "$WRAPPER" --version 2>&1)
wrc=$?
set -e
if [ "$wrc" -eq 0 ] && printf '%s\n' "$out" | grep -q "$V"; then
    ok "wrapper runs end-to-end, claude --version reports $V"
else
    bad "wrapper end-to-end" "rc=$wrc, out=$out"
fi

#-----------------------------------------------------------------------
section "UID/GID remap (file written inside container is host-owned)"

set +e
work="$TMP/work"
mkdir -p "$work"
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

# Run with the same flag set the wrapper composes for $PWD.
"$runtime" run --rm \
    -v "$work:$work" -w "$work" \
    -e HOST_UID="$HOST_UID" -e HOST_GID="$HOST_GID" \
    "$IMG" \
    sh -c 'touch inside-file && stat -c "%u:%g" inside-file' \
    >"$TMP/uid.out" 2>"$TMP/uid.err"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    in_owner=$(cat "$TMP/uid.out" | tr -d '\r\n')
    if [ "$in_owner" = "$HOST_UID:$HOST_GID" ]; then
        ok "in-container stat reports host UID:GID ($in_owner)"
    else
        bad "in-container ownership" "got '$in_owner', expected '$HOST_UID:$HOST_GID'"
    fi

    if [ -f "$work/inside-file" ]; then
        host_owner=$(stat -f "%u:%g" "$work/inside-file" 2>/dev/null \
                  || stat -c "%u:%g" "$work/inside-file" 2>/dev/null)
        if [ "$host_owner" = "$HOST_UID:$HOST_GID" ]; then
            ok "file on host is owned by host user ($host_owner)"
        else
            bad "host-side ownership" "got '$host_owner', expected '$HOST_UID:$HOST_GID'"
        fi
    else
        bad "host file missing" "no inside-file in $work"
    fi
else
    bad "container exec failed" "rc=$rc, err=$(cat "$TMP/uid.err")"
fi

#-----------------------------------------------------------------------
section "Bind-mount isolation (host paths not in mounts are invisible)"

set +e
# /Users doesn't exist inside a Linux container unless we bind-mount it.
"$runtime" run --rm \
    -v "$work:$work" -w "$work" \
    -e HOST_UID="$HOST_UID" -e HOST_GID="$HOST_GID" \
    "$IMG" \
    sh -c 'ls /Users 2>&1; echo "EXIT=$?"' \
    >"$TMP/iso.out" 2>&1
set -e

if grep -qE '(No such file|not found|EXIT=[1-9])' "$TMP/iso.out"; then
    ok "/Users is not visible inside the container"
else
    bad "isolation breach" "container could see /Users: $(cat "$TMP/iso.out")"
fi

#-----------------------------------------------------------------------
section "Read-only mount enforcement (~/.gitconfig and ~/.ssh)"

# Create fake host files that we mount ro into the container.
mkdir -p "$TMP/sshdir"
echo "[user]" > "$TMP/gitconfig"
echo "k" > "$TMP/sshdir/key"

set +e
"$runtime" run --rm \
    -v "$TMP/gitconfig:/home/claude/.gitconfig:ro" \
    -v "$TMP/sshdir:/home/claude/.ssh:ro" \
    -e HOST_UID="$HOST_UID" -e HOST_GID="$HOST_GID" \
    "$IMG" \
    sh -c 'echo modified > /home/claude/.gitconfig 2>&1; echo "GIT_EXIT=$?"; touch /home/claude/.ssh/added 2>&1; echo "SSH_EXIT=$?"' \
    >"$TMP/ro.out" 2>&1
set -e

if grep -qE 'GIT_EXIT=[^0]' "$TMP/ro.out"; then
    ok "write to ro ~/.gitconfig is rejected"
else
    bad "gitconfig write was allowed" "$(cat "$TMP/ro.out")"
fi
if grep -qE 'SSH_EXIT=[^0]' "$TMP/ro.out"; then
    ok "write to ro ~/.ssh is rejected"
else
    bad "ssh write was allowed" "$(cat "$TMP/ro.out")"
fi

# And the underlying host files should be untouched.
if [ "$(cat "$TMP/gitconfig")" = "[user]" ]; then
    ok "host gitconfig contents unchanged"
else
    bad "host gitconfig was modified" "$(cat "$TMP/gitconfig")"
fi

#-----------------------------------------------------------------------
section "Signal handling (SIGTERM reaches PID 1 through gosu)"

# Linux's kernel ignores signals delivered to PID 1 unless PID 1 has
# explicitly installed a handler. Plain `sleep` doesn't, so testing with
# sleep would (incorrectly) appear to show broken signal delivery. We
# model the real case — Claude installs handlers — by using a sh that
# traps SIGTERM and exits. That proves both: (a) gosu used execve so the
# command becomes true PID 1, and (b) the runtime actually delivers the
# requested signal.
cidfile="$TMP/cid"; rm -f "$cidfile"
start=$(date +%s)
(
    "$runtime" run --rm --cidfile "$cidfile" \
        -e HOST_UID="$HOST_UID" -e HOST_GID="$HOST_GID" \
        "$IMG" \
        sh -c 'trap "exit 0" TERM INT; while sleep 1; do :; done' \
        >/dev/null 2>&1
) &
bgpid=$!

# Wait up to 5s for the container to start (cidfile populated).
for _ in 1 2 3 4 5; do
    [ -s "$cidfile" ] && break
    sleep 1
done

cid=$(cat "$cidfile" 2>/dev/null || true)
if [ -z "$cid" ]; then
    bad "container didn't start in time"
    kill "$bgpid" 2>/dev/null
else
    "$runtime" kill --signal SIGTERM "$cid" >/dev/null 2>&1 || true
    wait "$bgpid" 2>/dev/null || true
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -lt 10 ]; then
        ok "container exited ${elapsed}s after SIGTERM (signal reached trapping PID 1 through gosu)"
    else
        bad "signal not propagated" "container ran for ${elapsed}s before exiting"
    fi
fi

#-----------------------------------------------------------------------
section "Phase 3 subcommands against real runtime"

# `version` should report runtime + image label, and not crash.
out=$(cd "$TMP/proj" && \
      ISOCLAUDE_HOME="$ISO_HOME" \
      ISOCLAUDE_BASE_IMAGE="$WRAPPER_IMG" \
      ISOCLAUDE_RUNTIME="$runtime" \
      "$WRAPPER" version 2>&1)
case "$out" in
    *"global pin:"*"$V"*"image label:"*"$V"*"runtime:"*"$runtime"*)
        ok "version reports pin, label, and runtime correctly" ;;
    *) bad "version output" "got: $out" ;;
esac

# `init` should create the scaffold idempotently.
init_dir="$TMP/init-target"
mkdir -p "$init_dir"
( cd "$init_dir" && \
      ISOCLAUDE_HOME="$ISO_HOME" \
      ISOCLAUDE_RUNTIME="$runtime" \
      "$WRAPPER" init >/dev/null 2>&1 )
[ -f "$init_dir/.isoclaude/Dockerfile" ] && [ -f "$init_dir/.isoclaude/env" ] \
    && ok "init scaffolds .isoclaude/ end-to-end" || bad "init missed files"

# `shell` should launch bash. We use a one-shot command (-c) so it exits
# immediately rather than blocking on a prompt.
out=$(cd "$TMP/proj" && \
      ISOCLAUDE_HOME="$ISO_HOME" \
      ISOCLAUDE_BASE_IMAGE="$WRAPPER_IMG" \
      ISOCLAUDE_RUNTIME="$runtime" \
      "$WRAPPER" shell -c 'echo bash-says hello; id -un' 2>&1)
case "$out" in
    *bash-says\ hello*claude*)
        ok "shell runs bash inside container as claude user" ;;
    *) bad "shell exec" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "Phase 4 overlays end-to-end (env, mounts, project Dockerfile)"

# Build a project that exercises all three overlays.
proj4="$TMP/proj4"
mkdir -p "$proj4/.isoclaude/local"

echo 'COMMITTED_VAR=from-committed' > "$proj4/.isoclaude/env"
echo 'COMMITTED_VAR=from-local'     > "$proj4/.isoclaude/local/env"   # later wins
echo 'LOCAL_ONLY=yes'              >> "$proj4/.isoclaude/local/env"

mkdir -p "$TMP/extra-data"
echo "marker" > "$TMP/extra-data/marker.txt"
echo "$TMP/extra-data:/extra:ro" > "$proj4/.isoclaude/mounts"

cat > "$proj4/.isoclaude/Dockerfile" <<'EOF'
FROM isoclaude-base:latest
RUN echo project-layer-mark > /etc/iso-project-mark
EOF

# Run from inside the project dir so project_root + project Dockerfile fire.
out=$(cd "$proj4" && \
      ISOCLAUDE_HOME="$ISO_HOME" \
      ISOCLAUDE_BASE_IMAGE="$WRAPPER_IMG" \
      ISOCLAUDE_RUNTIME="$runtime" \
      "$WRAPPER" shell -c 'echo "COMMITTED=$COMMITTED_VAR"; echo "LOCAL=$LOCAL_ONLY"; cat /extra/marker.txt; echo "MARK=$(cat /etc/iso-project-mark)"' 2>&1)

case "$out" in
    *COMMITTED=from-local*) ok "local env overrides committed env at runtime" ;;
    *COMMITTED=from-committed*) bad "local env did not override" "got: $out" ;;
    *) bad "env var not set" "got: $out" ;;
esac
case "$out" in
    *LOCAL=yes*) ok "local-only env var visible inside container" ;;
    *) bad "local-only var missing" "got: $out" ;;
esac
case "$out" in
    *marker*) ok "extra bind mount is readable inside" ;;
    *) bad "extra mount missing" "got: $out" ;;
esac
case "$out" in
    *MARK=project-layer-mark*) ok "project Dockerfile layer is applied (file added by RUN visible)" ;;
    *) bad "project image not used" "got: $out" ;;
esac

# Clean up the project images we built so they don't accumulate.
for img in $("$runtime" image list 2>/dev/null | awk '/^isoclaude-project-/ {print $1":"$2}'); do
    "$runtime" image rm "$img" >/dev/null 2>&1 || true
done

#-----------------------------------------------------------------------
printf '\n\033[1mLive: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
