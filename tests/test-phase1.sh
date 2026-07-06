#!/usr/bin/env bash
# Phase 1 tests: image/Dockerfile.base and image/entrypoint.sh
#
# Without a container runtime available we can't actually build the image,
# but we can verify shape and syntax. An optional live-build path runs when
# a runtime is present.

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

#-----------------------------------------------------------------------
section "entrypoint.sh — syntax and POSIX compliance"

if sh -n image/entrypoint.sh 2>/dev/null; then
    ok "sh -n parses entrypoint.sh"
else
    bad "sh -n failed on entrypoint.sh"
fi

if bash -n image/entrypoint.sh 2>/dev/null; then
    ok "bash -n parses entrypoint.sh"
else
    bad "bash -n failed on entrypoint.sh"
fi

if [ -x image/entrypoint.sh ]; then
    ok "entrypoint.sh is executable"
else
    bad "entrypoint.sh is not executable"
fi

if head -1 image/entrypoint.sh | grep -q '^#!/usr/bin/env sh$'; then
    ok "entrypoint.sh uses POSIX sh shebang"
else
    bad "entrypoint.sh shebang is wrong (expected /usr/bin/env sh)"
fi

#-----------------------------------------------------------------------
section "entrypoint.sh — required behavior"

ep=image/entrypoint.sh
grep -q '\-u "\$target" claude'             "$ep"  && ok "remap_uid runs usermod -u"   || bad "missing usermod -u"
grep -q 'groupmod -g'                       "$ep"  && ok "groupmod -g runs"  || bad "missing groupmod -g"
grep -q '\-g "\$target" claude'             "$ep"  && ok "handles GID collisions via usermod -g" || bad "no GID-collision handling"
grep -q 'Failed to change ownership'        "$ep"  && ok "filters known-harmless usermod chown_tree error" || bad "no filter for usermod chown noise"
grep -q 'getent group'                      "$ep"  && ok "probes existing groups before remap" || bad "missing getent group probe"
grep -q 'getent passwd'                     "$ep"  && ok "probes existing users before UID remap" || bad "missing getent passwd probe"
grep -q 'exec gosu claude'                  "$ep"  && ok "exec gosu drops privs" || bad "missing exec gosu"
grep -q 'isoclaude-pty-filter'              "$ep"  && ok "routes interactive claude through pty mouse filter" || bad "no pty-filter route"
grep -q 'ISOCLAUDE_MOUSE_FILTER'            "$ep"  && ok "mouse filter has env opt-out" || bad "no ISOCLAUDE_MOUSE_FILTER gate"
grep -q '\[ -t 1 \]'                        "$ep"  && ok "mouse filter gated on stdout TTY" || bad "filter would wrap non-TTY (claude -p) runs"
grep -q '\! -name .claude'                  "$ep"  && ok "skips .claude bind mount on chown" || bad "would chown bind-mounted .claude"
grep -q '\! -name .gitconfig'               "$ep"  && ok "skips .gitconfig bind mount on chown" || bad "would chown ro .gitconfig mount"
grep -q '\! -name .ssh'                     "$ep"  && ok "skips .ssh bind mount on chown" || bad "would chown ro .ssh mount"
grep -q '^set -e'                           "$ep"  && ok "errexit enabled" || bad "missing set -e"

#-----------------------------------------------------------------------
section "Dockerfile.base — required directives"

df=image/Dockerfile.base
grep -q '^FROM debian:'                     "$df" && ok "FROM debian-based image"        || bad "missing/wrong FROM"
grep -q '^ARG CLAUDE_VERSION'               "$df" && ok "CLAUDE_VERSION build-arg"       || bad "missing CLAUDE_VERSION ARG"
grep -q 'CLAUDE_VERSION.*required'          "$df" && ok "build fails when arg is empty"  || bad "no guard on empty CLAUDE_VERSION"
grep -q 'npm install -g .*@anthropic-ai/claude-code@'  "$df" && ok "installs pinned claude-code" || bad "npm install line missing"
grep -q 'gosu'                              "$df" && ok "installs gosu"                  || bad "gosu missing from apt install"
grep -q 'nodesource'                        "$df" && ok "uses nodesource for node 22"    || bad "node install line missing"
grep -q 'cli.github.com/packages'           "$df" && ok "adds GitHub CLI apt source"    || bad "gh apt source missing"
grep -q 'githubcli-archive-keyring.gpg'     "$df" && ok "installs github-cli keyring"   || bad "gh keyring missing"
grep -q 'signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg' \
                                            "$df" && ok "gh apt list pins signed-by keyring" || bad "gh source not signed-by-pinned"
grep -qE '(^|\s)gh(\s|$)'                   "$df" && ok "installs gh package"           || bad "gh package not in apt install list"
grep -q 'useradd .*-u 1000 .*claude'        "$df" && ok "creates claude user at UID 1000" || bad "no useradd for claude"
grep -q "safe.directory '\*'"               "$df" && ok "git safe.directory configured for bind mounts" || bad "missing git safe.directory"
grep -q ' sudo'                             "$df" && ok "installs sudo (for passwordless apt as claude)" || bad "sudo not installed"
grep -q "claude ALL=(ALL) NOPASSWD: ALL"    "$df" && ok "claude user has passwordless sudo" || bad "no sudoers rule for claude"
grep -q '/etc/sudoers.d/claude'             "$df" && ok "sudoers rule lives in /etc/sudoers.d/claude" || bad "sudoers rule not in sudoers.d"
grep -q 'COPY entrypoint.sh'                "$df" && ok "copies entrypoint into image"   || bad "entrypoint not copied"
grep -q 'COPY mouse-filter.js'              "$df" && ok "copies mouse filter into image" || bad "mouse-filter.js not copied"
grep -q 'COPY pty-filter.sh /usr/local/bin/isoclaude-pty-filter' \
                                            "$df" && ok "installs pty-filter wrapper"    || bad "pty-filter not installed"
grep -q '^LABEL isoclaude.claude_version='  "$df" && ok "tags image with version label"  || bad "missing version label"
grep -q '^ENTRYPOINT'                       "$df" && ok "sets ENTRYPOINT"                || bad "missing ENTRYPOINT"
grep -q '^CMD \["claude"\]'                 "$df" && ok "CMD defaults to claude"         || bad "wrong/missing CMD"
grep -q '^ENV HOME=/home/claude'            "$df" && ok "HOME set to /home/claude"       || bad "HOME env not set"

#-----------------------------------------------------------------------
section "Dockerfile.base — image hygiene"

grep -q 'apt-get clean'                     "$df" && ok "apt-get clean called"           || bad "apt-get clean missing"
grep -q 'rm -rf /var/lib/apt/lists'         "$df" && ok "apt cache cleaned"              || bad "apt cache not cleaned"
grep -q 'no-install-recommends'             "$df" && ok "uses --no-install-recommends"   || bad "should use --no-install-recommends"

#-----------------------------------------------------------------------
section "mouse filter — syntax and behavior"

if bash -n image/pty-filter.sh 2>/dev/null; then
    ok "bash -n parses pty-filter.sh"
else
    bad "bash -n failed on pty-filter.sh"
fi

if command -v node >/dev/null 2>&1; then
    if node --check image/mouse-filter.js 2>/dev/null; then
        ok "node --check parses mouse-filter.js"
    else
        bad "mouse-filter.js has syntax errors"
    fi

    # Behavioral: strips mouse enables, keeps alt-screen + disables.
    out=$(printf '\x1b[?1000hA\x1b[?1002h\x1b[?1003h\x1b[?1006hB\x1b[?1049h\x1b[?1000lC' \
          | node image/mouse-filter.js | od -An -c | tr -d ' \n')
    case "$out" in
        'AB033[?1049h033[?1000lC') ok "filter strips ?1000/?1002/?1003/?1006 enables, keeps ?1049h and disables" ;;
        *) bad "filter output wrong" "got: $out" ;;
    esac

    # Chunk-boundary: a sequence split across writes must still be stripped.
    out=$(python3 -c "
import subprocess
p = subprocess.Popen(['node', 'image/mouse-filter.js'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
data = b'X\x1b[?1000hY'
for i in range(len(data)):
    p.stdin.write(data[i:i+1]); p.stdin.flush()
p.stdin.close()
print(p.stdout.read().decode())
")
    [ "$out" = "XY" ] && ok "filter handles sequences split across chunks" \
        || bad "chunk-boundary handling broken" "got: $out"
else
    printf '  \033[33mskip\033[0m no node on PATH for filter behavior tests\n'
fi

#-----------------------------------------------------------------------
section "Live build (skipped when no runtime is available)"

for rt in docker podman orb container; do
    if command -v "$rt" >/dev/null 2>&1; then
        runtime="$rt"
        break
    fi
done

if [ -z "${runtime:-}" ]; then
    printf '  \033[33mskip\033[0m no container runtime on PATH\n'
else
    v="2.1.143"
    printf '  using runtime: %s\n' "$runtime"
    # Disable set -e for the live-build section so a runtime-specific quirk
    # (like Apple container exiting nonzero on an unknown flag) doesn't bail
    # the whole script — we want all checks to report independently.
    set +e

    if "$runtime" build --build-arg "CLAUDE_VERSION=$v" \
                  -t isoclaude-base-test:latest \
                  -f image/Dockerfile.base image/ >/tmp/iso-build.log 2>&1; then
        ok "image builds with CLAUDE_VERSION=$v"

        # Extract the label via JSON parsing (works on docker, podman, AND
        # Apple container, the last of which has no --format support).
        got=$("$runtime" image inspect isoclaude-base-test:latest 2>/dev/null | python3 -c '
import sys, json
try: data = json.load(sys.stdin)
except Exception: sys.exit(0)
KEY = "isoclaude.claude_version"
def walk(o):
    if isinstance(o, dict):
        lab = o.get("Labels") or o.get("labels")
        if isinstance(lab, dict) and lab.get(KEY): return lab[KEY]
        for v in o.values():
            r = walk(v)
            if r: return r
    elif isinstance(o, list):
        for v in o:
            r = walk(v)
            if r: return r
v = walk(data)
if v: print(v)
' 2>/dev/null)
        if [ "$got" = "$v" ]; then
            ok "image label matches build-arg ($got)"
        else
            bad "image label is '$got', expected '$v'"
        fi

        # Run claude --version through the full entrypoint chain.
        # Without HOST_UID set the usermod path is skipped; gosu still
        # drops privs to the claude user, then runs `claude --version`.
        out=$("$runtime" run --rm isoclaude-base-test:latest claude --version 2>&1)
        if printf '%s\n' "$out" | grep -q "$v"; then
            ok "claude --version reports $v inside container (full entrypoint)"
        else
            bad "claude --version output didn't contain '$v': $out"
        fi

        "$runtime" image rm isoclaude-base-test:latest >/dev/null 2>&1
    else
        bad "image build failed; see /tmp/iso-build.log"
    fi

    set -e
fi

#-----------------------------------------------------------------------
printf '\n\033[1mPhase 1: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
