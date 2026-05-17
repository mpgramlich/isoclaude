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
grep -q 'usermod  *-u "\$HOST_UID" claude'  "$ep"  && ok "usermod -u runs"  || bad "missing usermod -u"
grep -q 'groupmod -g .* claude'             "$ep"  && ok "groupmod -g runs" || bad "missing groupmod -g"
grep -q 'exec gosu claude'                  "$ep"  && ok "exec gosu drops privs" || bad "missing exec gosu"
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
grep -q 'useradd .*-u 1000 .*claude'        "$df" && ok "creates claude user at UID 1000" || bad "no useradd for claude"
grep -q 'COPY entrypoint.sh'                "$df" && ok "copies entrypoint into image"   || bad "entrypoint not copied"
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
    if "$runtime" build --build-arg "CLAUDE_VERSION=$v" \
                  -t isoclaude-base-test:latest \
                  -f image/Dockerfile.base image/ >/tmp/iso-build.log 2>&1; then
        ok "image builds with CLAUDE_VERSION=$v"
        # Verify label was written
        got=$("$runtime" image inspect --format '{{ index .Config.Labels "isoclaude.claude_version" }}' isoclaude-base-test:latest 2>/dev/null)
        if [ "$got" = "$v" ]; then
            ok "image label matches build-arg ($got)"
        else
            bad "image label is '$got', expected '$v'"
        fi
        # Verify claude is on PATH inside
        if "$runtime" run --rm --entrypoint /bin/sh isoclaude-base-test:latest -c 'command -v claude && claude --version' | grep -q "$v"; then
            ok "claude --version reports $v inside container"
        else
            bad "claude not runnable or wrong version inside container"
        fi
        "$runtime" image rm isoclaude-base-test:latest >/dev/null 2>&1 || true
    else
        bad "image build failed; see /tmp/iso-build.log"
    fi
fi

#-----------------------------------------------------------------------
printf '\n\033[1mPhase 1: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
