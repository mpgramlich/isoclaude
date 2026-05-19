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
printf '\n\033[1mPhase 5: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
