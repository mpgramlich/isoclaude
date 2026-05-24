#!/usr/bin/env bash
# Phase 5 tests: install.sh, isoclaude uninstall, isoclaude prune.
#
# All tests run against an isolated tmp HOME and tmp prefix dir, with a
# fake docker/npm on PATH. Nothing on the real system is touched.

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO/bin/isoclaude"
INSTALL="$REPO/install.sh"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

#-----------------------------------------------------------------------
section "Test harness"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/fakebin"
# Fake docker: log argv, fake image list, succeed at build/rm.
cat > "$TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_DOCKER_LOG"
case "$1" in
    image)
        case "$2" in
            list|ls)
                # Print a docker-style table of whatever FAKE_IMAGES says.
                printf 'REPOSITORY\tTAG\tIMAGE ID\tCREATED\tSIZE\n'
                for img in ${FAKE_IMAGES:-}; do
                    name="${img%:*}"; tag="${img#*:}"
                    printf '%s\t%s\tdeadbeef\tjust now\t100MB\n' "$name" "$tag"
                done
                ;;
            inspect)
                target="$3"
                if [ -n "${FAKE_LABEL:-}" ] && [ "$target" = "isoclaude-base:latest" ]; then
                    printf '[{"Config":{"Labels":{"isoclaude.claude_version":"%s"}}}]\n' "$FAKE_LABEL"
                    exit 0
                fi
                for existing in ${FAKE_IMAGES:-}; do
                    [ "$existing" = "$target" ] && exit 0
                done
                exit 1
                ;;
            rm)
                # Pretend remove succeeded.
                exit 0
                ;;
        esac
        ;;
    build) exit 0 ;;
    run)   exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/fakebin/docker"

# Fake npm: returns NPM_FAKE_VERSION on `npm view ... version`.
cat > "$TMP/fakebin/npm" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_NPM_LOG"
if [ "$1" = "view" ] && [ "$3" = "version" ]; then
    printf '%s\n' "${NPM_FAKE_VERSION:-2.0.0}"
fi
exit 0
EOF
chmod +x "$TMP/fakebin/npm"

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$HOME/.ssh"
echo "[user]" > "$HOME/.gitconfig"
echo "k" > "$HOME/.ssh/id_ed25519"

export ISOCLAUDE_HOME="$HOME/.isoclaude"
export PATH="$TMP/fakebin:$PATH"
export FAKE_DOCKER_LOG="$TMP/docker.log"
export FAKE_NPM_LOG="$TMP/npm.log"

ok "tmp HOME=$HOME"
ok "fake docker + npm on PATH"

#-----------------------------------------------------------------------
section "install.sh — happy path with --prefix and --version"

PREFIX="$TMP/install/bin"
: > "$FAKE_DOCKER_LOG"; : > "$FAKE_NPM_LOG"
rm -rf "$ISOCLAUDE_HOME"

# --no-build keeps the test deterministic and quick.
"$INSTALL" --prefix "$PREFIX" --version "1.2.3" --no-build \
    >"$TMP/install.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "install.sh exits 0" || bad "install.sh rc=$rc; out=$(cat "$TMP/install.out")"

[ -x "$PREFIX/isoclaude" ] && ok "wrapper installed to --prefix" || bad "wrapper missing at $PREFIX/isoclaude"
cmp -s "$PREFIX/isoclaude" "$REPO/bin/isoclaude" \
    && ok "wrapper bytes match repo source" || bad "installed wrapper differs from source"

[ -f "$ISOCLAUDE_HOME/Dockerfile.base" ] && ok "seeded Dockerfile.base" || bad "Dockerfile.base missing"
[ -f "$ISOCLAUDE_HOME/entrypoint.sh"   ] && ok "seeded entrypoint.sh"   || bad "entrypoint.sh missing"
pin=$(cat "$ISOCLAUDE_HOME/claude-version")
[ "$pin" = "1.2.3" ] && ok "global pin = 1.2.3 (from --version)" || bad "pin=$pin"

# --version skips the npm call entirely.
[ ! -s "$FAKE_NPM_LOG" ] && ok "--version skips npm" || bad "npm was called: $(cat "$FAKE_NPM_LOG")"

# --no-build skips the build call.
grep -q '^build' "$FAKE_DOCKER_LOG" && bad "--no-build still triggered build" \
    || ok "--no-build skips pre-build"

#-----------------------------------------------------------------------
section "install.sh — npm fallback when no --version"

PREFIX2="$TMP/install2/bin"
rm -rf "$ISOCLAUDE_HOME"
: > "$FAKE_NPM_LOG"
NPM_FAKE_VERSION="3.4.5" "$INSTALL" --prefix "$PREFIX2" --no-build \
    >/dev/null 2>&1
pin=$(cat "$ISOCLAUDE_HOME/claude-version")
[ "$pin" = "3.4.5" ] && ok "no --version -> pin from npm view" || bad "pin=$pin"
grep -q 'view @anthropic-ai/claude-code version' "$FAKE_NPM_LOG" \
    && ok "made the expected npm view call" \
    || bad "npm log: $(cat "$FAKE_NPM_LOG")"

#-----------------------------------------------------------------------
section "install.sh — re-run is idempotent, --force overwrites"

PREFIX3="$TMP/install3/bin"
"$INSTALL" --prefix "$PREFIX3" --version "1.0.0" --no-build >/dev/null 2>&1

# Same source → second install should be a no-op (no error).
"$INSTALL" --prefix "$PREFIX3" --version "1.0.0" --no-build \
    >"$TMP/reinstall.out" 2>&1 \
    && ok "re-install with identical wrapper exits 0" \
    || bad "re-install failed: $(cat "$TMP/reinstall.out")"

# If the destination differs and --force isn't passed, install should error.
printf 'tampered\n' > "$PREFIX3/isoclaude"
if "$INSTALL" --prefix "$PREFIX3" --version "1.0.0" --no-build \
        >"$TMP/conflict.out" 2>&1; then
    bad "install should have errored on tampered wrapper"
else
    ok "install errors when wrapper differs and --force absent"
fi

"$INSTALL" --prefix "$PREFIX3" --version "1.0.0" --no-build --force \
    >/dev/null 2>&1 \
    && cmp -s "$PREFIX3/isoclaude" "$REPO/bin/isoclaude" \
    && ok "--force overwrites tampered wrapper" \
    || bad "--force did not restore the wrapper"

#-----------------------------------------------------------------------
section "install.sh — pre-builds by default when runtime is present"

PREFIX4="$TMP/install4/bin"
rm -rf "$ISOCLAUDE_HOME"
: > "$FAKE_DOCKER_LOG"
ISOCLAUDE_RUNTIME=docker "$INSTALL" --prefix "$PREFIX4" --version "5.5.5" \
    >/dev/null 2>&1

# install.sh shells out to the freshly-installed wrapper for the build,
# which then logs `build ... CLAUDE_VERSION=5.5.5` via our fake docker.
if grep -q 'build .*CLAUDE_VERSION=5.5.5' "$FAKE_DOCKER_LOG"; then
    ok "pre-build invoked with the pinned version"
else
    bad "no pre-build" "log: $(cat "$FAKE_DOCKER_LOG")"
fi

#-----------------------------------------------------------------------
section "isoclaude prune (mocked)"

export ISOCLAUDE_RUNTIME="docker"
export ISOCLAUDE_BASE_IMAGE="isoclaude-base:latest"

rm -rf "$ISOCLAUDE_HOME"; mkdir -p "$ISOCLAUDE_HOME"
cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
echo "1.0.0" > "$ISOCLAUDE_HOME/claude-version"

# Three project images: one matches the current project's hash, two don't.
proj="$TMP/proj"
mkdir -p "$proj/.isoclaude"
cat > "$proj/.isoclaude/Dockerfile" <<'EOF'
FROM isoclaude-base:latest
RUN echo current
EOF

# Compute the current Dockerfile hash the same way the wrapper does.
if command -v sha256sum >/dev/null 2>&1; then
    chash=$(sha256sum "$proj/.isoclaude/Dockerfile" | cut -c1-12)
else
    chash=$(shasum -a 256 "$proj/.isoclaude/Dockerfile" | cut -c1-12)
fi
CURRENT_IMG="isoclaude-project-${chash}:latest"
OTHER1="isoclaude-project-aaaaaaaaaaaa:latest"
OTHER2="isoclaude-project-bbbbbbbbbbbb:latest"
export FAKE_IMAGES="$CURRENT_IMG $OTHER1 $OTHER2"

# Run prune from inside the project.
: > "$FAKE_DOCKER_LOG"
( cd "$proj" && FAKE_IMAGES="$FAKE_IMAGES" "$WRAPPER" prune 2>&1 ) >"$TMP/prune.out"

grep -q "image rm $OTHER1" "$FAKE_DOCKER_LOG" && ok "prune removes orphan #1" || bad "no rm for $OTHER1"
grep -q "image rm $OTHER2" "$FAKE_DOCKER_LOG" && ok "prune removes orphan #2" || bad "no rm for $OTHER2"
if grep -q "image rm $CURRENT_IMG" "$FAKE_DOCKER_LOG"; then
    bad "prune removed the current project's image!"
else
    ok "prune preserves current project image"
fi
grep -q "pruned 2 project image(s)" "$TMP/prune.out" \
    && ok "prune reports the correct count" \
    || bad "wrong count" "out: $(cat "$TMP/prune.out")"

# --all should nuke everything including current.
: > "$FAKE_DOCKER_LOG"
( cd "$proj" && FAKE_IMAGES="$FAKE_IMAGES" "$WRAPPER" prune --all >/dev/null 2>&1 )
grep -q "image rm $CURRENT_IMG" "$FAKE_DOCKER_LOG" && ok "--all also removes current" || bad "--all missed current"

# No project images at all: clean exit, "pruned 0".
: > "$FAKE_DOCKER_LOG"
out=$(FAKE_IMAGES="" "$WRAPPER" prune 2>&1)
case "$out" in *"pruned 0 project image"*) ok "no-images case reports 0 pruned" ;;
    *) bad "no-images case" "got: $out" ;;
esac
if grep -q '^image rm' "$FAKE_DOCKER_LOG"; then
    bad "prune called image rm with nothing to prune"
else
    ok "prune doesn't call image rm when there's nothing to remove"
fi

#-----------------------------------------------------------------------
section "isoclaude uninstall (mocked, --yes)"

# Re-seed the home dir we just nuked.
rm -rf "$ISOCLAUDE_HOME"; mkdir -p "$ISOCLAUDE_HOME"
cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
echo "1.0.0" > "$ISOCLAUDE_HOME/claude-version"

# Copy the wrapper into a writable place so uninstall can rm it.
SELF="$TMP/install5/bin/isoclaude"
mkdir -p "$(dirname "$SELF")"
cp "$WRAPPER" "$SELF"
chmod +x "$SELF"

: > "$FAKE_DOCKER_LOG"
FAKE_IMAGES="isoclaude-base:latest isoclaude-project-aaaa:latest" \
    "$SELF" uninstall --yes >/dev/null 2>&1

[ ! -f "$SELF" ]            && ok "uninstall removed the wrapper"      || bad "$SELF still exists"
[ ! -d "$ISOCLAUDE_HOME" ]  && ok "uninstall removed ~/.isoclaude/"    || bad "iso home still exists"
# No --purge: images are NOT removed.
if grep -q '^image rm' "$FAKE_DOCKER_LOG"; then
    bad "uninstall removed images without --purge"
else
    ok "uninstall preserves images by default"
fi

# --purge variant.
rm -rf "$ISOCLAUDE_HOME"; mkdir -p "$ISOCLAUDE_HOME"
cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
echo "1.0.0" > "$ISOCLAUDE_HOME/claude-version"
SELF2="$TMP/install6/bin/isoclaude"
mkdir -p "$(dirname "$SELF2")"
cp "$WRAPPER" "$SELF2"; chmod +x "$SELF2"

: > "$FAKE_DOCKER_LOG"
FAKE_IMAGES="isoclaude-base:latest isoclaude-project-cccc:latest" \
    "$SELF2" uninstall --purge --yes >/dev/null 2>&1

grep -q 'image rm isoclaude-base:latest'           "$FAKE_DOCKER_LOG" \
    && ok "--purge removes the base image" || bad "base not purged"
grep -q 'image rm isoclaude-project-cccc:latest'   "$FAKE_DOCKER_LOG" \
    && ok "--purge removes project images too" || bad "project not purged"

# Cancellation path: input "no" → nothing removed.
rm -rf "$ISOCLAUDE_HOME"; mkdir -p "$ISOCLAUDE_HOME"
cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
SELF3="$TMP/install7/bin/isoclaude"
mkdir -p "$(dirname "$SELF3")"
cp "$WRAPPER" "$SELF3"; chmod +x "$SELF3"

out=$(printf 'n\n' | "$SELF3" uninstall 2>&1)
case "$out" in *"cancelled"*) ok "answering 'n' cancels uninstall" ;;
    *) bad "no cancel message" "got: $out" ;;
esac
[ -f "$SELF3" ] && ok "wrapper preserved after cancellation" || bad "wrapper removed despite cancel"

#-----------------------------------------------------------------------
section "isoclaude sync-auth (macOS keychain bridge)"

# Mock the macOS `security` CLI: success returns the canned credential.
cat > "$TMP/fakebin/security" <<'EOF'
#!/usr/bin/env bash
# Only the `find-generic-password -s "Claude Code-credentials" [-w]` form
# matters for our test. Other invocations are ignored.
case " $* " in
    *" -s Claude\\ Code-credentials "*|*" -s 'Claude Code-credentials' "*|*" -s Claude\ Code-credentials "*)
        ;;
esac
last=""
want=0
for a in "$@"; do
    case "$a" in
        -w) want=1 ;;
        Claude*credentials*) last="$a" ;;
    esac
done
[ "$last" = "Claude Code-credentials" ] || exit 1
if [ -n "${FAKE_KEYCHAIN_HAS_CRED:-}" ]; then
    if [ "$want" -eq 1 ]; then
        printf '%s\n' "${FAKE_KEYCHAIN_PAYLOAD:-{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-fake\"}}}"
    fi
    exit 0
fi
exit 1
EOF
chmod +x "$TMP/fakebin/security"

# Fake `uname` so the macOS-only code paths trigger on whatever host runs the tests.
cat > "$TMP/fakebin/uname" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_UNAME:-}" = "" ] && exec /usr/bin/uname "$@"
printf '%s\n' "$FAKE_UNAME"
EOF
chmod +x "$TMP/fakebin/uname"

# Re-source the wrapper so it picks up the fake uname (script_dir caches BASH_SOURCE
# so this is fine).
# shellcheck disable=SC1090
. "$WRAPPER"

# Happy path: keychain has the cred, sync-auth writes the file.
rm -f "$HOME/.claude/.credentials.json"
FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 cmd_sync_auth >/dev/null 2>&1 \
    && ok "sync-auth exits 0 when keychain has the credential" \
    || bad "sync-auth failed unexpectedly"
[ -f "$HOME/.claude/.credentials.json" ] \
    && ok "sync-auth wrote ~/.claude/.credentials.json" \
    || bad "credentials file not written"
perms=$(stat -f %p "$HOME/.claude/.credentials.json" 2>/dev/null \
     || stat -c %a "$HOME/.claude/.credentials.json" 2>/dev/null)
case "$perms" in
    *600|600) ok "credentials file is chmod 600" ;;
    *) bad "wrong perms: $perms" ;;
esac
grep -q 'claudeAiOauth' "$HOME/.claude/.credentials.json" \
    && ok "credentials file contains the keychain payload" \
    || bad "wrong file contents"

# No keychain entry → sync-auth errors and doesn't leave a stub file.
# cmd_sync_auth calls `die` which `exit`s, so we wrap in a subshell.
rm -f "$HOME/.claude/.credentials.json"
if ( FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED="" cmd_sync_auth 2>/dev/null ); then
    bad "sync-auth should error when keychain has no credential"
else
    ok "sync-auth errors when no keychain credential"
fi
[ ! -f "$HOME/.claude/.credentials.json" ] \
    && ok "sync-auth leaves no stub file on failure" \
    || bad "stub file written"

# Non-macOS → sync-auth refuses.
if ( FAKE_UNAME="Linux" cmd_sync_auth 2>/dev/null ); then
    bad "sync-auth should refuse on non-macOS"
else
    ok "sync-auth refuses on non-macOS"
fi

# _macos_auth_refresh: Darwin + keychain cred + missing file → silent refresh.
rm -f "$HOME/.claude/.credentials.json"
out=$(FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 _macos_auth_refresh 2>&1)
case "$out" in
    *"refreshed ~/.claude/.credentials.json"*)
        ok "_macos_auth_refresh creates the file when missing" ;;
    *) bad "missing-file path" "got: $out" ;;
esac
[ -f "$HOME/.claude/.credentials.json" ] \
    && ok "_macos_auth_refresh actually wrote the file" \
    || bad "no file after refresh"

# When the file already matches the keychain payload, refresh is silent.
out=$(FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 _macos_auth_refresh 2>&1)
[ -z "$out" ] && ok "silent when file is already current" \
    || bad "spurious refresh log" "got: $out"

# When the file has stale contents, refresh updates and logs.
echo 'stale-content' > "$HOME/.claude/.credentials.json"
out=$(FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 _macos_auth_refresh 2>&1)
case "$out" in
    *"refreshed"*) ok "refresh updates a stale file" ;;
    *) bad "no refresh log on stale file" "got: $out" ;;
esac
grep -q 'claudeAiOauth' "$HOME/.claude/.credentials.json" \
    && ok "stale file is now in sync with keychain" \
    || bad "file still stale after refresh"

# Keychain empty + existing file → leave the file alone (don't blow away stale auth).
out=$(FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED="" _macos_auth_refresh; echo "rc=$?")
case "$out" in
    *rc=0*) ok "rc=0 when file exists despite empty keychain (caller can keep using it)" ;;
    *) bad "rc on empty-keychain-with-file" "got: $out" ;;
esac
[ -f "$HOME/.claude/.credentials.json" ] \
    && ok "preserves existing file when keychain is empty" \
    || bad "file was deleted"

# Keychain empty + no file → return 1 so caller can warn.
# (`rc=0; (sub) || rc=$?` captures the subshell's nonzero exit without
# tripping set -e in the parent.)
rm -f "$HOME/.claude/.credentials.json"
rc=0; ( FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED="" _macos_auth_refresh ) || rc=$?
[ "$rc" -eq 1 ] && ok "returns 1 when keychain empty AND no file" || bad "wrong rc: $rc"

# Non-macOS → rc=2, no warning, no file changes.
rc=0; ( FAKE_UNAME="Linux" _macos_auth_refresh ) || rc=$?
[ "$rc" -eq 2 ] && ok "returns 2 on non-macOS (caller silently skips)" || bad "wrong rc: $rc"

#-----------------------------------------------------------------------
section "isoclaude doctor"

# Reset to a known-good state for doctor checks.
rm -rf "$ISOCLAUDE_HOME"; mkdir -p "$ISOCLAUDE_HOME"
cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
echo "1.2.3" > "$ISOCLAUDE_HOME/claude-version"
echo '{}' > "$HOME/.claude.json"
echo "[user]" > "$HOME/.gitconfig"
mkdir -p "$HOME/.ssh"; echo "k" > "$HOME/.ssh/id_ed25519"
rm -f "$HOME/.claude/.credentials.json"

# Helper: run doctor with the fake runtime + fake security/uname; capture
# stdout and exit code separately. Runs from a clean dir (no .isoclaude/
# anywhere up to /tmp) so the "no project" assertion is stable regardless
# of which dir the test harness was invoked from.
mkdir -p "$TMP/clean"
run_doctor() {
    out=""; rc=0
    out=$( cd "$TMP/clean" && "$WRAPPER" doctor 2>&1 ) || rc=$?
}

#--- Happy path: all the bits the harness controls are healthy.
FAKE_LABEL="1.2.3" FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 \
    run_doctor
case "$out" in
    *"Runtime"*"Wrapper"*"Pin & image"*"Auth"*"Project"*) ok "doctor prints all 5 sections in order" ;;
    *) bad "section order" "got: $out" ;;
esac
[ "$rc" -eq 0 ] && ok "exits 0 on healthy state" || bad "rc=$rc on healthy"
case "$out" in
    *"ISOCLAUDE_RUNTIME=docker"*|*"runtime detected: docker"*) ok "reports the runtime" ;;
    *) bad "no runtime line" "got: $out" ;;
esac
case "$out" in
    *"global pin: 1.2.3"*) ok "reports global pin" ;;
    *) bad "no pin line" ;;
esac
case "$out" in
    *"base image: $ISOCLAUDE_BASE_IMAGE @ 1.2.3"*) ok "reports image label match" ;;
    *) bad "no image-label line" ;;
esac
case "$out" in
    *"keychain ↔ ~/.claude/.credentials.json in sync"*) ok "reports keychain in sync (auto-refreshed by doctor itself? no — _macos_auth_refresh is gated on container launch)" ;;
    *"~/.claude/.credentials.json"*) ok "auth section mentions credentials file state" ;;
    *) bad "no credentials line" "got: $out" ;;
esac
case "$out" in
    *"no .isoclaude/ found"*) ok "reports no project when none present" ;;
    *) bad "project section" "got: $out" ;;
esac

#--- Image label mismatch (pin moved, image hasn't been rebuilt yet)
FAKE_LABEL="0.0.1" FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 \
    run_doctor
case "$out" in
    *"label (0.0.1) differs from pin (1.2.3)"*"next run will rebuild"*) ok "warns on label/pin drift" ;;
    *) bad "drift warning" "got: $out" ;;
esac
[ "$rc" -eq 0 ] && ok "drift is a warn, not an error (rc=0)" || bad "drift triggered rc=$rc"

#--- Daemon not reachable (fake docker fails image list)
cat > "$TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    image)
        if [ "$2" = "list" ] || [ "$2" = "ls" ]; then
            echo "Cannot connect" >&2
            exit 1
        fi
        if [ "$2" = "inspect" ]; then exit 1; fi
        ;;
esac
exit 0
EOF
chmod +x "$TMP/fakebin/docker"
run_doctor
case "$out" in
    *"image list\` failed"*) ok "errors when runtime daemon is down" ;;
    *) bad "no daemon error" "got: $out" ;;
esac
[ "$rc" -eq 1 ] && ok "exits 1 on runtime error" || bad "rc=$rc on runtime error"

# Restore the working fake docker for the remaining tests.
cat > "$TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_DOCKER_LOG"
case "$1" in
    image)
        case "$2" in
            list|ls) printf 'REPO\tTAG\tID\tCREATED\tSIZE\n'; exit 0 ;;
            inspect)
                target="$3"
                if [ -n "${FAKE_LABEL:-}" ] && [ "$target" = "isoclaude-base:latest" ]; then
                    printf '[{"Config":{"Labels":{"isoclaude.claude_version":"%s"}}}]\n' "$FAKE_LABEL"
                    exit 0
                fi
                exit 1
                ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$TMP/fakebin/docker"

#--- No pin set at all
rm -f "$ISOCLAUDE_HOME/claude-version"
FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 run_doctor
case "$out" in
    *"no global pin"*) ok "warns when no global pin set" ;;
    *) bad "no-pin warning" "got: $out" ;;
esac
[ "$rc" -eq 0 ] && ok "missing pin is warn, not error" || bad "rc=$rc on missing pin"

#--- Image not built yet
echo "1.2.3" > "$ISOCLAUDE_HOME/claude-version"
unset FAKE_LABEL
FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 run_doctor
case "$out" in
    *"base image not built yet"*) ok "warns when base image missing" ;;
    *) bad "no unbuilt-image warning" ;;
esac

#--- macOS, keychain empty, no credentials file
FAKE_LABEL="1.2.3" FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED="" \
    rm -f "$HOME/.claude/.credentials.json"
FAKE_LABEL="1.2.3" FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED="" run_doctor
case "$out" in
    *"no host login found"*"run host"*claude*login*) ok "auth section points at host /login when nothing is configured" ;;
    *) bad "no-login guidance" "got: $out" ;;
esac

#--- macOS, keychain has cred, file is stale
echo 'stale' > "$HOME/.claude/.credentials.json"
FAKE_LABEL="1.2.3" FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 run_doctor
case "$out" in
    *"different credentials"*"sync-auth"*) ok "warns on stale credentials file" ;;
    *) bad "no stale-cred warning" "got: $out" ;;
esac

#--- macOS, keychain has cred, file is in sync
rm -f "$HOME/.claude/.credentials.json"
FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 _macos_auth_refresh >/dev/null 2>&1
FAKE_LABEL="1.2.3" FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 run_doctor
case "$out" in
    *"in sync"*) ok "reports sync OK when keychain and file match" ;;
    *) bad "sync-ok line missing" "got: $out" ;;
esac

#--- Project: with a project root, env file, project Dockerfile
mkdir -p "$TMP/proj/.isoclaude"
echo "9.9.9" > "$TMP/proj/.isoclaude/claude-version"
echo "FOO=bar" > "$TMP/proj/.isoclaude/env"
cat > "$TMP/proj/.isoclaude/Dockerfile" <<'EOF'
FROM isoclaude-base:latest
RUN echo proj
EOF
( cd "$TMP/proj" && FAKE_LABEL="1.2.3" FAKE_UNAME="Darwin" FAKE_KEYCHAIN_HAS_CRED=1 \
    out=$("$WRAPPER" doctor 2>&1); echo "$out" ) > "$TMP/proj.doctor"
case "$(cat "$TMP/proj.doctor")" in
    *"project root: $TMP/proj"*"project pin: 9.9.9"*".isoclaude/env present"*) ok "project section lists root, pin, and env" ;;
    *) bad "project section" "got: $(cat "$TMP/proj.doctor")" ;;
esac
case "$(cat "$TMP/proj.doctor")" in
    *"project image isoclaude-project-"*"not built"*) ok "project section reports unbuilt project image" ;;
    *) bad "project image line missing" ;;
esac

#-----------------------------------------------------------------------
printf '\n\033[1mPhase 5: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
