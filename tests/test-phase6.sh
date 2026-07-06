#!/usr/bin/env bash
# Phase 6 tests: --keep / persistent-container lifecycle.
#
# Covers:
#   - --keep / -k / ISOCLAUDE_KEEP flag parsing
#   - compose_run_flags drops --rm and adds the cmd-file mount when KEEP=1
#   - _container_name is deterministic per PWD+image
#   - _exec_in_sandbox dispatches: missing+keep → run --name (no --rm),
#     stopped → start -ai, running → exec, missing+!keep → run --rm
#   - cmd file is written with shell-quoted argv (printf %q)
#   - --no-keep forces ephemeral even when a container "exists"
#   - cmd_stop / cmd_rm / cmd_ps run cleanly against the fake runtime

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
# Resolve TMP through symlinks so comparisons match the wrapper's
# canonical (cd -P) output.
TMP="$(cd -P "$TMP" && pwd -P)"

# Fake docker that the dispatcher's `inspect` and `list` probes can drive
# via env vars. Each invocation also gets logged for argv inspection.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_DOCKER_LOG"
case "$1" in
    inspect)
        # FAKE_STATE drives the dispatcher:
        #   ""       → exit nonzero (container missing)
        #   running  → JSON with status=running
        #   stopped  → JSON with status=stopped
        if [ -z "${FAKE_STATE:-}" ]; then
            exit 1
        fi
        printf '[{"State":{"Status":"%s"}}]\n' "$FAKE_STATE"
        exit 0
        ;;
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
    list)
        # cmd_ps / _list_pwd_containers consume this. Empty JSON array
        # by default; tests that need entries set FAKE_LIST_JSON.
        printf '%s\n' "${FAKE_LIST_JSON:-[]}"
        exit 0
        ;;
    network)
        # FAKE_OFFLINE_NET_EXISTS=1 → inspect returns non-empty JSON;
        # 0 (default) → empty []. create always succeeds.
        if [ "$2" = "inspect" ]; then
            if [ "${FAKE_OFFLINE_NET_EXISTS:-0}" = "1" ]; then
                printf '[{"name":"isoclaude-offline"}]\n'
            else
                printf '[]\n'
            fi
            exit 0
        fi
        if [ "$2" = "create" ]; then
            echo "1" > "${FAKE_OFFLINE_NET_FLAG:-/dev/null}"
            exit 0
        fi
        exit 0
        ;;
    build|run|stop|rm|start|exec) exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/fakebin/docker"

# Mirror the fake docker as a `container` binary too — _ensure_offline_network
# short-circuits on non-container runtimes, so we need an actual `container`
# command for those tests. Same logging target.
ln -sf docker "$TMP/fakebin/container"

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$HOME/.ssh"
echo "[user]" > "$HOME/.gitconfig"
echo "k" > "$HOME/.ssh/id_ed25519"

export ISOCLAUDE_HOME="$HOME/.isoclaude"
export ISOCLAUDE_RUNTIME="docker"
export ISOCLAUDE_BASE_IMAGE="isoclaude-base:test"
export PATH="$TMP/fakebin:$PATH"
export FAKE_DOCKER_LOG="$TMP/docker.log"

# shellcheck disable=SC1090
. "$WRAPPER"
ok "wrapper sourced"

reset() {
    rm -rf "$ISOCLAUDE_HOME" "$TMP/proj"
    mkdir -p "$ISOCLAUDE_HOME" "$TMP/proj"
    cp "$REPO/image/Dockerfile.base" "$ISOCLAUDE_HOME/Dockerfile.base"
    cp "$REPO/image/entrypoint.sh"   "$ISOCLAUDE_HOME/entrypoint.sh"
    echo "1.2.3" > "$ISOCLAUDE_HOME/claude-version"
    : > "$FAKE_DOCKER_LOG"
    unset FAKE_LABEL FAKE_STATE FAKE_LIST_JSON
    export FAKE_LABEL="1.2.3"  # base image is "built"
    YOLO=0
    KEEP=0
    OFFLINE=0
    OWN_AUTH=0
    FORCE_EPHEMERAL=0
    PROJECT_ROOT=""
    unset FAKE_OFFLINE_NET_EXISTS
    # Dry-run so the dispatcher prints its invocation instead of exec'ing
    # the fake docker (which produces no stdout for run/start/exec).
    export ISOCLAUDE_DRY_RUN=1
    export ISOCLAUDE_AUTH_REFRESH=0
    cd "$TMP/proj"
}

#-----------------------------------------------------------------------
section "Container-name derivation"

reset
RUN_IMAGE="isoclaude-base:test"
name1="$(_container_name)"
name2="$(_container_name)"
[ "$name1" = "$name2" ] && ok "_container_name is deterministic" \
    || bad "name not deterministic" "$name1 vs $name2"

case "$name1" in
    isoclaude-*-*) ok "_container_name has expected isoclaude-<pwd>-<img> shape" ;;
    *) bad "name shape" "got: $name1" ;;
esac

# Different image → different name (so an image rebuild orphans the old
# container instead of silently reusing one with stale rootfs).
RUN_IMAGE="isoclaude-base:test" ; a="$(_container_name)"
RUN_IMAGE="isoclaude-base:other"; b="$(_container_name)"
[ "$a" != "$b" ] && ok "different image → different name" \
    || bad "image tag not part of name" "both: $a"

# Different PWD → different name
RUN_IMAGE="isoclaude-base:test"
a="$(_container_name)"
mkdir -p "$TMP/other" && b="$(cd "$TMP/other" && _container_name)"
[ "$a" != "$b" ] && ok "different PWD → different name" \
    || bad "PWD not part of name" "both: $a"
cd "$TMP/proj"

#-----------------------------------------------------------------------
section "compose_run_flags honors KEEP"

reset
KEEP=0
RUN_FLAGS=()
compose_run_flags
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"--rm"*) ok "KEEP=0 keeps --rm" ;;
    *) bad "ephemeral path missing --rm" "flags: $flags" ;;
esac
case "$flags" in
    *"/home/claude/.isoclaude/cmd"*) bad "cmd mount added when KEEP=0" "flags: $flags" ;;
    *) ok "no cmd mount when KEEP=0" ;;
esac

reset
KEEP=1
RUN_FLAGS=()
compose_run_flags
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"--rm"*) bad "KEEP=1 still has --rm" "flags: $flags" ;;
    *) ok "KEEP=1 drops --rm" ;;
esac
case "$flags" in
    *":/home/claude/.isoclaude/cmd:ro"*) ok "KEEP=1 adds cmd-file mount ro" ;;
    *) bad "KEEP=1 missing cmd mount" "flags: $flags" ;;
esac
[ -f "$TMP/proj/.isoclaude/local/cmd" ] && ok "KEEP=1 created cmd file" \
    || bad "cmd file not created"

#-----------------------------------------------------------------------
section "_container_state JSON parsing"

reset
export FAKE_STATE=""
[ -z "$(_container_state docker isoclaude-foo)" ] \
    && ok "missing container → empty state" || bad "missing not empty"

export FAKE_STATE="running"
[ "$(_container_state docker isoclaude-foo)" = "running" ] \
    && ok "Status=running parsed as 'running'" || bad "running parse"

export FAKE_STATE="stopped"
[ "$(_container_state docker isoclaude-foo)" = "stopped" ] \
    && ok "Status=stopped parsed as 'stopped'" || bad "stopped parse"

export FAKE_STATE="exited"
[ "$(_container_state docker isoclaude-foo)" = "stopped" ] \
    && ok "Status=exited normalized to 'stopped'" || bad "exited not normalized"

#-----------------------------------------------------------------------
section "_exec_in_sandbox dispatch — missing + KEEP=1 → run --name (no --rm)"

reset
KEEP=1
export FAKE_STATE=""
_prepare
out="$(_exec_in_sandbox docker claude --resume X 2>/dev/null | tail -1)"
case "$out" in
    *"docker run"*) ok "uses run when missing" ;;
    *) bad "wrong verb" "got: $out" ;;
esac
case "$out" in
    *"--rm"*) bad "KEEP=1 still emits --rm" "got: $out" ;;
    *) ok "no --rm" ;;
esac
case "$out" in
    *"--name isoclaude-"*) ok "passes --name" ;;
    *) bad "no --name" "got: $out" ;;
esac
case "$out" in
    *"claude --resume X") bad "argv leaked through CMD instead of file" "got: $out" ;;
    *) ok "argv goes via cmd file, not CMD" ;;
esac
[ -f "$TMP/proj/.isoclaude/local/cmd" ] \
    && grep -q 'claude --resume X' "$TMP/proj/.isoclaude/local/cmd" \
    && ok "cmd file contains 'claude --resume X'" \
    || bad "cmd file wrong" "got: $(cat "$TMP/proj/.isoclaude/local/cmd" 2>/dev/null)"

#-----------------------------------------------------------------------
section "_exec_in_sandbox dispatch — stopped → start -ai"

reset
KEEP=1
export FAKE_STATE="stopped"
_prepare
out="$(_exec_in_sandbox docker claude --resume Y 2>/dev/null | tail -1)"
case "$out" in
    *"docker start -a -i isoclaude-"*) ok "stopped → start -a -i <name>" ;;
    *) bad "stopped dispatch" "got: $out" ;;
esac
grep -q 'claude --resume Y' "$TMP/proj/.isoclaude/local/cmd" \
    && ok "stopped path rewrites cmd file with fresh args" \
    || bad "cmd file not refreshed" "got: $(cat "$TMP/proj/.isoclaude/local/cmd")"

#-----------------------------------------------------------------------
section "_exec_in_sandbox dispatch — running → exec"

reset
KEEP=1
export FAKE_STATE="running"
_prepare
out="$(_exec_in_sandbox docker claude --resume Z 2>/dev/null | tail -1)"
case "$out" in
    *"docker exec"*"isoclaude-"*"claude --resume Z") ok "running → exec <name> claude ..." ;;
    *) bad "running dispatch" "got: $out" ;;
esac
case "$out" in
    *"-u claude"*) ok "exec drops to claude user" ;;
    *) bad "exec missing -u claude" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "_exec_in_sandbox dispatch — missing + KEEP=0 → run --rm (original)"

reset
KEEP=0
export FAKE_STATE=""
_prepare
out="$(_exec_in_sandbox docker claude --resume W 2>/dev/null | tail -1)"
case "$out" in
    *"docker run"*"--rm"*) ok "ephemeral uses run --rm" ;;
    *) bad "ephemeral path" "got: $out" ;;
esac
case "$out" in
    *"--name isoclaude-"*) bad "ephemeral emitted --name" "got: $out" ;;
    *) ok "ephemeral has no --name" ;;
esac
case "$out" in
    *"claude --resume W") ok "ephemeral passes argv through CMD" ;;
    *) bad "ephemeral CMD" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "Sticky persistence — KEEP auto-on when container already exists"

reset
KEEP=0          # user did NOT pass --keep
export FAKE_STATE="stopped"  # but a persistent container already exists
_prepare
out="$(_exec_in_sandbox docker claude 2>/dev/null | tail -1)"
case "$out" in
    *"docker start -a -i"*) ok "existing container auto-resumed without --keep" ;;
    *"docker run"*) bad "ignored existing container" "got: $out" ;;
    *) bad "auto-resume" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "--no-keep forces ephemeral past an existing container"

reset
KEEP=0
FORCE_EPHEMERAL=1
export FAKE_STATE="running"   # would normally exec into it
_prepare
out="$(_exec_in_sandbox docker claude 2>/dev/null | tail -1)"
case "$out" in
    *"docker run --rm"*) ok "--no-keep forces fresh ephemeral run" ;;
    *) bad "--no-keep did not bypass" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "_write_persist_cmd handles spaces and special chars"

reset
_write_persist_cmd "$TMP/cmdfile" claude --resume "has spaces" -- "weird'quote"
got="$(cat "$TMP/cmdfile")"
# After eval, the argv should reconstruct exactly. Test via re-eval.
eval "set -- $got"
[ "$#" = 5 ] && ok "_write_persist_cmd: argc preserved ($#)" || bad "argc" "got $#"
[ "$3" = "has spaces" ] && ok "_write_persist_cmd: spaces preserved" \
    || bad "spaces" "got '$3'"
[ "$5" = "weird'quote" ] && ok "_write_persist_cmd: single quote preserved" \
    || bad "quote" "got '$5'"

#-----------------------------------------------------------------------
section "Flag parsing — --keep / -k / ISOCLAUDE_KEEP / --no-keep"

RUN_WRAPPER() {
    ISOCLAUDE_HOME="$ISOCLAUDE_HOME" \
    ISOCLAUDE_RUNTIME=docker \
    ISOCLAUDE_BASE_IMAGE="$ISOCLAUDE_BASE_IMAGE" \
    ISOCLAUDE_DRY_RUN=1 \
    ISOCLAUDE_AUTH_REFRESH=0 \
    PATH="$PATH" HOME="$HOME" \
    FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
    FAKE_LABEL="1.2.3" \
    "$WRAPPER" "$@"
}

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --keep 2>&1 | tail -1)
case "$out" in
    *"--name isoclaude-"*) ok "--keep before subcommand enables persistence" ;;
    *) bad "--keep before" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER run --keep 2>&1 | tail -1)
case "$out" in
    *"--name isoclaude-"*) ok "--keep after subcommand enables persistence" ;;
    *) bad "--keep after" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -k 2>&1 | tail -1)
case "$out" in
    *"--name isoclaude-"*) ok "-k short alias" ;;
    *) bad "-k" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && ISOCLAUDE_KEEP=1 RUN_WRAPPER 2>&1 | tail -1)
case "$out" in
    *"--name isoclaude-"*) ok "ISOCLAUDE_KEEP=1 env var" ;;
    *) bad "ISOCLAUDE_KEEP env" "got: $out" ;;
esac

# Default — neither flag nor env → ephemeral
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER 2>&1 | tail -1)
case "$out" in
    *"--name isoclaude-"*) bad "default added --name" "got: $out" ;;
    *"--rm"*) ok "default is ephemeral (--rm, no --name)" ;;
    *) bad "default" "got: $out" ;;
esac

# --keep after `--` is a literal claude arg
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -- --keep 2>&1 | tail -1)
case "$out" in
    *"--name isoclaude-"*) bad "--keep after -- was consumed" "got: $out" ;;
    *claude*--keep*) ok "--keep after -- passes through as a literal arg" ;;
    *) bad "after-dashdash" "got: $out" ;;
esac

#-----------------------------------------------------------------------
section "Lifecycle subcommands — cmd_stop / cmd_rm / cmd_ps"

reset
# Make _list_pwd_containers return one entry.
pwd_real="$(cd -P "$PWD" && pwd -P)"
pwd_hash="$(_short_hash "$pwd_real" 12)"
export FAKE_LIST_JSON='[{"name":"isoclaude-'"$pwd_hash"'-aaaaaaaa","status":"stopped"}]'

out="$(cmd_stop 2>&1)"
case "$out" in
    *"stopped isoclaude-${pwd_hash}-"*) ok "cmd_stop matches PWD-hash prefix" ;;
    *"no running container"*) ok "cmd_stop tolerates stop failure" ;;
    *) bad "cmd_stop" "got: $out" ;;
esac

out="$(cmd_rm 2>&1)"
case "$out" in
    *"removed isoclaude-${pwd_hash}-"*) ok "cmd_rm matches PWD-hash prefix" ;;
    *) bad "cmd_rm" "got: $out" ;;
esac

# cmd_ps lists ALL isoclaude-* containers regardless of PWD.
export FAKE_LIST_JSON='[{"name":"isoclaude-aaa-bbb","status":"running"},{"name":"unrelated","status":"running"}]'
out="$(cmd_ps 2>&1)"
case "$out" in
    *"isoclaude-aaa-bbb"*"running"*) ok "cmd_ps shows isoclaude container with state" ;;
    *) bad "cmd_ps" "got: $out" ;;
esac
case "$out" in
    *unrelated*) bad "cmd_ps showed unrelated container" "got: $out" ;;
    *) ok "cmd_ps filters non-isoclaude containers" ;;
esac

# Empty list — no output, no crash.
export FAKE_LIST_JSON='[]'
cmd_ps >/dev/null 2>&1 && ok "cmd_ps handles empty list" || bad "cmd_ps empty crashed"

#-----------------------------------------------------------------------
section "Help text mentions persistence"

reset
out="$(cmd_help)"
for tok in "--keep" "stop" "rm" "ps" "ISOCLAUDE_KEEP" "--no-keep"; do
    case "$out" in
        *"$tok"*) ok "help mentions '$tok'" ;;
        *) bad "help missing '$tok'" ;;
    esac
done

#-----------------------------------------------------------------------
#-----------------------------------------------------------------------
section "Offline mode (--offline / -o / ISOCLAUDE_OFFLINE)"

# Flag parsing — same RUN_WRAPPER as the --keep tests.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --offline 2>/dev/null | tail -1)
case "$out" in
    *"--network none"*) ok "--offline → --network none on docker runtime" ;;
    *) bad "--offline" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -o 2>/dev/null | tail -1)
case "$out" in
    *"--network none"*) ok "-o short alias" ;;
    *) bad "-o" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && ISOCLAUDE_OFFLINE=1 RUN_WRAPPER 2>/dev/null | tail -1)
case "$out" in
    *"--network none"*) ok "ISOCLAUDE_OFFLINE=1 env var" ;;
    *) bad "ISOCLAUDE_OFFLINE env" "got: $out" ;;
esac

# Control: no --offline → no --network in flags.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER 2>/dev/null | tail -1)
case "$out" in
    *"--network"*) bad "default emitted --network" "got: $out" ;;
    *) ok "default has no --network" ;;
esac

# Runtime-aware emission: container (Apple) → --network isoclaude-offline + --no-dns
reset
export FAKE_OFFLINE_NET_EXISTS=1   # skip the create path in this test
out="$(OFFLINE=1 _add_offline_flags container; printf '%s ' "${RUN_FLAGS[@]}")"
RUN_FLAGS=()
_add_offline_flags container
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"--network isoclaude-offline"*) ok "container runtime → --network isoclaude-offline" ;;
    *) bad "container offline flags" "flags: $flags" ;;
esac
case "$flags" in
    *"--no-dns"*) ok "container runtime → --no-dns (belt and braces)" ;;
    *) bad "missing --no-dns" "flags: $flags" ;;
esac

reset
RUN_FLAGS=()
_add_offline_flags docker
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"--network none"*) ok "docker runtime → --network none" ;;
    *) bad "docker offline flags" "flags: $flags" ;;
esac
case "$flags" in
    *"--no-dns"*) bad "docker shouldn't emit --no-dns" "flags: $flags" ;;
    *) ok "docker doesn't emit --no-dns" ;;
esac

reset
RUN_FLAGS=()
_add_offline_flags podman
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"--network none"*) ok "podman runtime → --network none" ;;
    *) bad "podman offline flags" "flags: $flags" ;;
esac

# Network create skipped when the network already exists. inspect should
# be called, network create should NOT be called.
reset
export FAKE_OFFLINE_NET_EXISTS=1
: > "$FAKE_DOCKER_LOG"
RUN_FLAGS=()
_ensure_offline_network container
grep -q 'network inspect isoclaude-offline' "$FAKE_DOCKER_LOG" \
    && ok "ensure: probes with network inspect" \
    || bad "ensure: missing inspect call" "log: $(cat "$FAKE_DOCKER_LOG")"
grep -q 'network create' "$FAKE_DOCKER_LOG" \
    && bad "ensure: should NOT create when network exists" "log: $(cat "$FAKE_DOCKER_LOG")" \
    || ok "ensure: skips create when network exists"

# Network create runs when network is missing.
reset
unset FAKE_OFFLINE_NET_EXISTS
: > "$FAKE_DOCKER_LOG"
RUN_FLAGS=()
_ensure_offline_network container >/dev/null 2>&1
grep -q 'network create --internal isoclaude-offline' "$FAKE_DOCKER_LOG" \
    && ok "ensure: creates network when missing" \
    || bad "ensure: no create call" "log: $(cat "$FAKE_DOCKER_LOG")"

# Apple container's `inspect` quirk: returns 0 with empty array `[]` for
# missing networks. The probe should treat `[]` as missing, not present.
reset
unset FAKE_OFFLINE_NET_EXISTS    # inspect returns []
: > "$FAKE_DOCKER_LOG"
_ensure_offline_network container >/dev/null 2>&1
grep -q 'network create' "$FAKE_DOCKER_LOG" \
    && ok "ensure: '[]' inspect output treated as missing (not exit code)" \
    || bad "ensure: '[]' wrongly treated as present" "log: $(cat "$FAKE_DOCKER_LOG")"

# Offline + persistence interplay: --offline + --keep should emit both
# --network isoclaude-offline and --name on a create.
reset
export FAKE_OFFLINE_NET_EXISTS=1
out=$(cd "$TMP/proj" && ISOCLAUDE_RUNTIME=container RUN_WRAPPER --keep --offline 2>/dev/null | tail -1)
# Above forces container runtime via the fake docker rename trick? We
# don't have a fake `container` binary; switch to docker-mode and check
# --network none + --name together.
out=$(cd "$TMP/proj" && RUN_WRAPPER --keep --offline 2>/dev/null | tail -1)
case "$out" in
    *"--network none"*"--name isoclaude-"*|*"--name isoclaude-"*"--network none"*) ok "--keep + --offline both emitted" ;;
    *) bad "--keep + --offline combo" "got: $out" ;;
esac

# Help mentions --offline / ISOCLAUDE_OFFLINE.
out="$(cmd_help)"
for tok in "--offline" "ISOCLAUDE_OFFLINE"; do
    case "$out" in
        *"$tok"*) ok "help mentions '$tok'" ;;
        *) bad "help missing '$tok'" ;;
    esac
done

#-----------------------------------------------------------------------
#-----------------------------------------------------------------------
section "Port publishing (--publish / -p / .isoclaude/ports)"

# _add_publish_spec direct: full spec, untouched.
reset
RUN_FLAGS=()
_add_publish_spec "8080:80" "CLI"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    "-p 8080:80") ok "_add_publish_spec: full spec passes through" ;;
    *) bad "full spec emission" "flags: $flags" ;;
esac

# _add_publish_spec direct: bare numeric → shorthand expansion.
reset
RUN_FLAGS=()
_add_publish_spec "8080" "CLI"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    "-p 8080:8080") ok "_add_publish_spec: bare port expands to N:N" ;;
    *) bad "shorthand expansion" "flags: $flags" ;;
esac

# _add_publish_spec direct: bare-with-protocol shorthand.
reset
RUN_FLAGS=()
_add_publish_spec "53/udp" "CLI"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    "-p 53:53/udp") ok "_add_publish_spec: N/proto expands to N:N/proto" ;;
    *) bad "proto shorthand" "flags: $flags" ;;
esac

# _add_publish_spec direct: full spec with host IP, untouched.
reset
RUN_FLAGS=()
_add_publish_spec "127.0.0.1:8080:80" "CLI"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    "-p 127.0.0.1:8080:80") ok "_add_publish_spec: host-ip spec preserved" ;;
    *) bad "host-ip spec" "flags: $flags" ;;
esac

# Empty / comment lines short-circuit cleanly.
reset
RUN_FLAGS=()
_add_publish_spec "" "CLI"
_add_publish_spec "#comment" "CLI"
[ "${#RUN_FLAGS[@]}" = 0 ] && ok "empty/comment specs produce no flags" \
    || bad "empty/comment emitted" "flags: ${RUN_FLAGS[*]}"

# Malformed spec → warn and skip (RUN_FLAGS untouched).
reset
RUN_FLAGS=()
_add_publish_spec "garbage-no-colon" "CLI" 2>/dev/null
[ "${#RUN_FLAGS[@]}" = 0 ] && ok "malformed spec is dropped" \
    || bad "malformed spec was added" "flags: ${RUN_FLAGS[*]}"

# .isoclaude/ports file: comments, blanks, shorthand all handled.
reset
mkdir -p "$TMP/proj/.isoclaude"
cat > "$TMP/proj/.isoclaude/ports" <<'EOF'
# vite dev
5173

8080:80
53/udp
EOF
RUN_FLAGS=()
_add_project_ports "$TMP/proj/.isoclaude/ports"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"-p 5173:5173"*"-p 8080:80"*"-p 53:53/udp"*) ok ".isoclaude/ports: all three entries emitted in order" ;;
    *) bad "ports file emission" "flags: $flags" ;;
esac

# Missing ports file is a clean no-op.
reset
RUN_FLAGS=()
_add_project_ports "$TMP/proj/does-not-exist-ports" 2>/dev/null
[ "${#RUN_FLAGS[@]}" = 0 ] && ok "missing ports file is a no-op" \
    || bad "missing file emitted" "flags: ${RUN_FLAGS[*]}"

# CLI --publish / -p (end-to-end via the subprocess wrapper).
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --publish 8080 2>/dev/null | tail -1)
case "$out" in
    *"-p 8080:8080"*) ok "--publish 8080 (long, shorthand)" ;;
    *) bad "--publish" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -p 5173:5173 -p 9000:90 2>/dev/null | tail -1)
case "$out" in
    *"-p 5173:5173"*"-p 9000:90"*) ok "-p repeatable preserves order" ;;
    *) bad "-p repeat" "got: $out" ;;
esac

# --publish= long form (= syntax).
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --publish=4000:4000 2>/dev/null | tail -1)
case "$out" in
    *"-p 4000:4000"*) ok "--publish=SPEC form" ;;
    *) bad "--publish=" "got: $out" ;;
esac

# Missing argument to --publish should die with a clear error. We
# `|| true` because the wrapper exits nonzero, and set -e would
# otherwise abort the whole test suite.
reset
out=$( { cd "$TMP/proj" && RUN_WRAPPER --publish; } 2>&1 | tail -1 || true)
case "$out" in
    *"requires an argument"*) ok "--publish without arg errors out" ;;
    *) bad "--publish missing arg" "got: $out" ;;
esac

# --publish after `--` is a literal claude arg, NOT a wrapper flag.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -- --publish foo 2>/dev/null | tail -1)
case "$out" in
    *"-p "*) bad "--publish after -- was consumed" "got: $out" ;;
    *claude*--publish*foo*) ok "--publish after -- passes through" ;;
    *) bad "after-dashdash" "got: $out" ;;
esac

# Project ports file + CLI --publish: BOTH appear, CLI last (so a
# duplicate-port -p from the CLI overrides the file under last-wins
# runtime semantics).
reset
mkdir -p "$TMP/proj/.isoclaude"
echo "8000" > "$TMP/proj/.isoclaude/ports"
out=$(cd "$TMP/proj" && RUN_WRAPPER -p 9999:99 2>/dev/null | tail -1)
case "$out" in
    *"-p 8000:8000"*"-p 9999:99"*) ok "project ports file + CLI -p both emitted, file first" ;;
    *) bad "file + CLI combo order" "got: $out" ;;
esac

# Help text mentions --publish and .isoclaude/ports.
out="$(cmd_help)"
for tok in "--publish" ".isoclaude/ports"; do
    case "$out" in
        *"$tok"*) ok "help mentions '$tok'" ;;
        *) bad "help missing '$tok'" ;;
    esac
done

#-----------------------------------------------------------------------
#-----------------------------------------------------------------------
section "Resource caps (--memory / -m / --cpus + env)"

# CLI --memory / -m: short and long forms.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -m 4g 2>/dev/null | tail -1)
case "$out" in
    *"-m 4g"*) ok "-m 4g passes through" ;;
    *) bad "-m" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --memory 8g 2>/dev/null | tail -1)
case "$out" in
    *"-m 8g"*) ok "--memory 8g passes through" ;;
    *) bad "--memory" "got: $out" ;;
esac

# = forms.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --memory=512m 2>/dev/null | tail -1)
case "$out" in
    *"-m 512m"*) ok "--memory=512m form" ;;
    *) bad "--memory=" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -m=1g 2>/dev/null | tail -1)
case "$out" in
    *"-m 1g"*) ok "-m=1g form" ;;
    *) bad "-m=" "got: $out" ;;
esac

# --cpus only has long form (docker parity).
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --cpus 2 2>/dev/null | tail -1)
case "$out" in
    *"--cpus 2"*) ok "--cpus 2 passes through" ;;
    *) bad "--cpus" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --cpus 0.5 2>/dev/null | tail -1)
case "$out" in
    *"--cpus 0.5"*) ok "--cpus 0.5 (fractional) passes through" ;;
    *) bad "fractional cpus" "got: $out" ;;
esac

reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --cpus=4 2>/dev/null | tail -1)
case "$out" in
    *"--cpus 4"*) ok "--cpus=4 form" ;;
    *) bad "--cpus=" "got: $out" ;;
esac

# Env vars.
reset
out=$(cd "$TMP/proj" && ISOCLAUDE_MEMORY=6g ISOCLAUDE_CPUS=3 RUN_WRAPPER 2>/dev/null | tail -1)
case "$out" in
    *"-m 6g"*"--cpus 3"*|*"--cpus 3"*"-m 6g"*) ok "ISOCLAUDE_MEMORY + ISOCLAUDE_CPUS env vars" ;;
    *) bad "env vars" "got: $out" ;;
esac

# CLI overrides env.
reset
out=$(cd "$TMP/proj" && ISOCLAUDE_MEMORY=2g RUN_WRAPPER -m 16g 2>/dev/null | tail -1)
case "$out" in
    *"-m 16g"*) ok "CLI -m overrides ISOCLAUDE_MEMORY env" ;;
    *) bad "CLI override" "got: $out" ;;
esac
case "$out" in
    *"-m 2g"*) bad "env value leaked alongside CLI" "got: $out" ;;
    *) ok "env value not double-emitted" ;;
esac

# Control: no flag, no env → no -m / --cpus at all.
reset
unset ISOCLAUDE_MEMORY ISOCLAUDE_CPUS
out=$(cd "$TMP/proj" && RUN_WRAPPER 2>/dev/null | tail -1)
case "$out" in
    *"-m "*) bad "emitted -m without ask" "got: $out" ;;
    *"--cpus"*) bad "emitted --cpus without ask" "got: $out" ;;
    *) ok "no -m / --cpus by default" ;;
esac

# Missing arg → die.
reset
out=$( { cd "$TMP/proj" && RUN_WRAPPER -m; } 2>&1 | tail -1 || true)
case "$out" in
    *"requires an argument"*) ok "-m without arg errors out" ;;
    *) bad "-m missing arg" "got: $out" ;;
esac

reset
out=$( { cd "$TMP/proj" && RUN_WRAPPER --cpus; } 2>&1 | tail -1 || true)
case "$out" in
    *"requires an argument"*) ok "--cpus without arg errors out" ;;
    *) bad "--cpus missing arg" "got: $out" ;;
esac

# --memory after `--` is a literal arg, not consumed.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -- --memory 9g 2>/dev/null | tail -1)
case "$out" in
    *"-m 9g"*) bad "--memory after -- was consumed" "got: $out" ;;
    *claude*--memory*) ok "--memory after -- passes through to claude" ;;
    *) bad "after-dashdash" "got: $out" ;;
esac

# Help text mentions both.
out="$(cmd_help)"
for tok in "--memory" "--cpus" "ISOCLAUDE_MEMORY" "ISOCLAUDE_CPUS"; do
    case "$out" in
        *"$tok"*) ok "help mentions '$tok'" ;;
        *) bad "help missing '$tok'" ;;
    esac
done

#-----------------------------------------------------------------------
section "Extra bind mounts (--volume / -v / .isoclaude/mounts)"

# Direct unit: _add_volume_spec passes a full spec through unchanged
# when the host path exists.
reset
mkdir -p "$TMP/extra"
RUN_FLAGS=()
_add_volume_spec "$TMP/extra:/data" "CLI"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    "-v $TMP/extra:/data") ok "_add_volume_spec: rw spec passes through" ;;
    *) bad "rw spec emission" "flags: $flags" ;;
esac

# :ro suffix preserved.
reset
mkdir -p "$TMP/extra"
RUN_FLAGS=()
_add_volume_spec "$TMP/extra:/data:ro" "CLI"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    "-v $TMP/extra:/data:ro") ok "_add_volume_spec: ro suffix preserved" ;;
    *) bad "ro suffix" "flags: $flags" ;;
esac

# Leading ~ expanded to $HOME.
reset
mkdir -p "$HOME/extra"
RUN_FLAGS=()
_add_volume_spec "~/extra:/data" "CLI"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    "-v $HOME/extra:/data") ok "_add_volume_spec: ~ expands to \$HOME" ;;
    *) bad "tilde expansion" "flags: $flags" ;;
esac

# Missing host path → warn, no flag.
reset
RUN_FLAGS=()
out=$(_add_volume_spec "$TMP/does-not-exist:/data" "CLI" 2>&1)
case "$out" in
    *"host path doesn't exist"*) ok "_add_volume_spec: warns on missing host" ;;
    *) bad "missing-host warning" "got: $out" ;;
esac
[ "${#RUN_FLAGS[@]}" = 0 ] && ok "_add_volume_spec: missing host emits no -v" \
    || bad "leaked missing-host flag" "flags: ${RUN_FLAGS[*]}"

# Missing colon → warn, no flag.
reset
RUN_FLAGS=()
out=$(_add_volume_spec "no-colon-here" "CLI" 2>&1)
case "$out" in
    *"skipping invalid mount spec"*) ok "_add_volume_spec: warns on missing colon" ;;
    *) bad "missing-colon warning" "got: $out" ;;
esac
[ "${#RUN_FLAGS[@]}" = 0 ] && ok "_add_volume_spec: missing colon emits no -v" \
    || bad "leaked missing-colon flag" "flags: ${RUN_FLAGS[*]}"

# Empty / comment lines → no flag.
reset
RUN_FLAGS=()
_add_volume_spec "" "CLI"
_add_volume_spec "#comment" "CLI"
[ "${#RUN_FLAGS[@]}" = 0 ] && ok "empty/comment volume specs produce no flags" \
    || bad "empty/comment emitted" "flags: ${RUN_FLAGS[*]}"

# CLI --volume / -v end-to-end.
reset
mkdir -p "$TMP/extra"
out=$(cd "$TMP/proj" && RUN_WRAPPER --volume "$TMP/extra:/data:ro" 2>/dev/null | tail -1)
case "$out" in
    *"-v $TMP/extra:/data:ro"*) ok "--volume passes through" ;;
    *) bad "--volume" "got: $out" ;;
esac

reset
mkdir -p "$TMP/extra"
out=$(cd "$TMP/proj" && RUN_WRAPPER -v "$TMP/extra:/data" 2>/dev/null | tail -1)
case "$out" in
    *"-v $TMP/extra:/data"*) ok "-v short alias" ;;
    *) bad "-v" "got: $out" ;;
esac

# Repeatable.
reset
mkdir -p "$TMP/extra" "$TMP/extra2"
out=$(cd "$TMP/proj" && RUN_WRAPPER -v "$TMP/extra:/a" -v "$TMP/extra2:/b:ro" 2>/dev/null | tail -1)
case "$out" in
    *"-v $TMP/extra:/a"*"-v $TMP/extra2:/b:ro"*) ok "-v repeatable preserves order" ;;
    *) bad "-v repeat" "got: $out" ;;
esac

# = form.
reset
mkdir -p "$TMP/extra"
out=$(cd "$TMP/proj" && RUN_WRAPPER "--volume=$TMP/extra:/data" 2>/dev/null | tail -1)
case "$out" in
    *"-v $TMP/extra:/data"*) ok "--volume=SPEC form" ;;
    *) bad "--volume=" "got: $out" ;;
esac

# Missing arg → die.
reset
out=$( { cd "$TMP/proj" && RUN_WRAPPER --volume; } 2>&1 | tail -1 || true)
case "$out" in
    *"requires an argument"*) ok "--volume without arg errors out" ;;
    *) bad "--volume missing arg" "got: $out" ;;
esac

# --volume after `--` is a literal claude arg.
reset
mkdir -p "$TMP/extra"
out=$(cd "$TMP/proj" && RUN_WRAPPER -- --volume "$TMP/extra:/data" 2>/dev/null | tail -1)
case "$out" in
    *"-v $TMP/extra:/data"*) bad "--volume after -- was consumed" "got: $out" ;;
    *claude*--volume*) ok "--volume after -- passes through" ;;
    *) bad "after-dashdash" "got: $out" ;;
esac

# .isoclaude/mounts file still works (refactor regression check).
reset
mkdir -p "$TMP/proj/.isoclaude" "$TMP/extra"
cat > "$TMP/proj/.isoclaude/mounts" <<EOF
# comment
$TMP/extra:/data:ro

$TMP/extra:/scratch
EOF
RUN_FLAGS=()
_add_project_mounts "$TMP/proj/.isoclaude/mounts"
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"-v $TMP/extra:/data:ro"*"-v $TMP/extra:/scratch"*) ok ".isoclaude/mounts: entries emitted in order, comments skipped" ;;
    *) bad "mounts file emission" "flags: $flags" ;;
esac

# Project mounts file + CLI -v: both appear, file first.
reset
mkdir -p "$TMP/proj/.isoclaude" "$TMP/extra" "$TMP/cli-extra"
echo "$TMP/extra:/from-file" > "$TMP/proj/.isoclaude/mounts"
out=$(cd "$TMP/proj" && RUN_WRAPPER -v "$TMP/cli-extra:/from-cli" 2>/dev/null | tail -1)
case "$out" in
    *"-v $TMP/extra:/from-file"*"-v $TMP/cli-extra:/from-cli"*) ok "project mounts file + CLI -v, file first" ;;
    *) bad "file + CLI combo" "got: $out" ;;
esac

# Help mentions --volume and .isoclaude/mounts.
out="$(cmd_help)"
for tok in "--volume" ".isoclaude/mounts"; do
    case "$out" in
        *"$tok"*) ok "help mentions '$tok'" ;;
        *) bad "help missing '$tok'" ;;
    esac
done

#-----------------------------------------------------------------------
section "Create-only flags don't leak into start/exec dispatch"
# Regression guard for the entire create-only-flag family: --memory,
# --cpus, --volume, --publish, and DISABLE_MOUSE are baked into the
# container at CREATE time. `container start` and `container exec` do
# NOT accept -m / --cpus / -v / -p / -e as run-time overrides. If the
# dispatcher ever started forwarding compose_run_flags to those
# branches, we'd emit invalid commands to the runtime. Pin the
# expected shape.
#
# All of the assertions here also implicitly cover DISABLE_MOUSE — its
# passthrough happens via `-e` inside compose_run_flags, alongside
# TERM/COLORTERM, and the start/exec paths bypass the whole flag list.

reset
KEEP=1
mkdir -p "$TMP/proj/extra"
export FAKE_STATE="stopped"
_prepare
# Put a full create-flag stack in play.
MEMORY=4g CPUS=2 \
    VOLUME=("$TMP/proj/extra:/data") \
    PUBLISH=(8080) \
    out="$(_exec_in_sandbox docker claude 2>/dev/null | tail -1)"
case "$out" in
    *"docker start -a -i isoclaude-"*) ok "stopped-dispatch stays as start -a -i" ;;
    *) bad "stopped dispatch shape drifted" "got: $out" ;;
esac
for tok in "-m " "--cpus" "-p " "-v " "DISABLE_MOUSE"; do
    case "$out" in
        *"$tok"*) bad "start branch leaked $tok" "got: $out" ;;
        *) ok "start branch omits '$tok'" ;;
    esac
done

reset
KEEP=1
mkdir -p "$TMP/proj/extra"
export FAKE_STATE="running"
_prepare
MEMORY=8g CPUS=4 \
    VOLUME=("$TMP/proj/extra:/data") \
    PUBLISH=(9000) \
    out="$(_exec_in_sandbox docker claude 2>/dev/null | tail -1)"
case "$out" in
    *"docker exec"*"isoclaude-"*claude*) ok "running-dispatch stays as exec <name> claude ..." ;;
    *) bad "running dispatch shape drifted" "got: $out" ;;
esac
for tok in "-m " "--cpus" "-p " "-v " "DISABLE_MOUSE"; do
    case "$out" in
        *"$tok"*) bad "exec branch leaked $tok" "got: $out" ;;
        *) ok "exec branch omits '$tok'" ;;
    esac
done

#-----------------------------------------------------------------------
section "Container-managed auth (--own-auth / ISOCLAUDE_OWN_AUTH / sticky marker)"

# --own-auth flag → OWN_AUTH=1 after main() parse.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER --own-auth 2>&1)
# When OWN_AUTH=1 in a fresh dir, the marker is created and a log line
# tells the user so.
case "$out" in
    *"recorded own-auth marker"*) ok "--own-auth logs marker creation on first use" ;;
    *) bad "no marker-creation log" "got: $out" ;;
esac
[ -f "$TMP/proj/.isoclaude/local/own-auth" ] && ok "--own-auth writes .isoclaude/local/own-auth marker" \
    || bad "marker file missing"

# ISOCLAUDE_OWN_AUTH=1 env var takes effect the same way.
reset
out=$(cd "$TMP/proj" && ISOCLAUDE_OWN_AUTH=1 RUN_WRAPPER 2>&1)
[ -f "$TMP/proj/.isoclaude/local/own-auth" ] && ok "ISOCLAUDE_OWN_AUTH=1 env writes marker" \
    || bad "env-var marker missing"

# Marker is sticky: pre-existing marker → OWN_AUTH auto-detected, no
# log line (already recorded), _macos_auth_check skipped.
reset
mkdir -p "$TMP/proj/.isoclaude/local"
: > "$TMP/proj/.isoclaude/local/own-auth"
out=$(cd "$TMP/proj" && RUN_WRAPPER 2>&1)
case "$out" in
    *"recorded own-auth marker"*) bad "sticky marker re-triggered creation log" "got: $out" ;;
    *) ok "sticky marker: no re-creation log" ;;
esac

# Guard actually skips _macos_auth_check when OWN_AUTH=1. Shadow the
# function with a probe that writes to a marker file, then verify
# whether the probe fires. This is observable regardless of whether the
# host keychain has a real entry (the previous "grep for warn"
# implementation passed vacuously on any logged-in dev machine).
reset
_macos_auth_check__real() { _macos_auth_check "$@"; }
_macos_auth_check() { echo "auth-check-fired" >> "$TMP/probe"; }
: > "$TMP/probe"
OWN_AUTH=1
RUN_FLAGS=()
compose_run_flags >/dev/null 2>&1 || true
[ ! -s "$TMP/probe" ] && ok "OWN_AUTH=1 skips _macos_auth_check (probe not called)" \
    || bad "OWN_AUTH=1 called _macos_auth_check" "probe: $(cat "$TMP/probe")"

# Control: OWN_AUTH=0 → probe fires.
reset
_macos_auth_check() { echo "auth-check-fired" >> "$TMP/probe"; }
: > "$TMP/probe"
OWN_AUTH=0
RUN_FLAGS=()
compose_run_flags >/dev/null 2>&1 || true
[ -s "$TMP/probe" ] && ok "OWN_AUTH=0 does invoke _macos_auth_check" \
    || bad "OWN_AUTH=0 skipped the check"
# Restore the real function so later tests see normal behavior.
unset -f _macos_auth_check 2>/dev/null || true
# Redefine from the wrapper source by re-sourcing (idempotent).
# shellcheck disable=SC1090
. "$WRAPPER" 2>/dev/null || true

# _spawn_auth_refresher guard: shadow it and drive _exec_in_sandbox
# through both the run-persistent and run-ephemeral paths.
reset
_spawn_auth_refresher() { echo "refresher-fired" >> "$TMP/probe"; }
: > "$TMP/probe"
OWN_AUTH=1
KEEP=1
export FAKE_STATE=""
_prepare
_exec_in_sandbox docker claude >/dev/null 2>&1 || true
[ ! -s "$TMP/probe" ] && ok "OWN_AUTH=1 skips _spawn_auth_refresher on persistent-run branch" \
    || bad "refresher fired on persistent-run despite OWN_AUTH=1"

reset
_spawn_auth_refresher() { echo "refresher-fired" >> "$TMP/probe"; }
: > "$TMP/probe"
OWN_AUTH=1
KEEP=0
export FAKE_STATE=""
_prepare
_exec_in_sandbox docker claude >/dev/null 2>&1 || true
[ ! -s "$TMP/probe" ] && ok "OWN_AUTH=1 skips _spawn_auth_refresher on ephemeral-run branch" \
    || bad "refresher fired on ephemeral-run despite OWN_AUTH=1"

reset
_spawn_auth_refresher() { echo "refresher-fired" >> "$TMP/probe"; }
: > "$TMP/probe"
OWN_AUTH=1
KEEP=1
export FAKE_STATE="stopped"
_prepare
_exec_in_sandbox docker claude >/dev/null 2>&1 || true
[ ! -s "$TMP/probe" ] && ok "OWN_AUTH=1 skips _spawn_auth_refresher on start branch" \
    || bad "refresher fired on start-branch despite OWN_AUTH=1"

# Belt-and-braces: verify all 3 refresher call sites are guarded in the
# wrapper source. The shadow tests above rely on the dispatcher NOT
# calling the (shadowed) real function under OWN_AUTH=1; that's dry-run-
# safe. A source-level regression check pins the guard shape too, so a
# future refactor that removes a guard fails loudly rather than
# vacuously.
n_guarded_calls=$(grep -c '\[ "${OWN_AUTH:-0}" = "1" \] || _spawn_auth_refresher' "$WRAPPER")
[ "$n_guarded_calls" -eq 3 ] \
    && ok "wrapper source has 3 OWN_AUTH-guarded _spawn_auth_refresher calls" \
    || bad "expected 3 guarded refresher calls in source, got $n_guarded_calls"

# Restore real functions.
unset -f _spawn_auth_refresher 2>/dev/null || true
# shellcheck disable=SC1090
. "$WRAPPER" 2>/dev/null || true

# --own-auth after `--` is a literal claude arg.
reset
out=$(cd "$TMP/proj" && RUN_WRAPPER -- --own-auth 2>/dev/null | tail -1)
case "$out" in
    *"claude"*"--own-auth"*) ok "--own-auth after -- passes through to claude" ;;
    *) bad "after-dashdash" "got: $out" ;;
esac

# --own-auth + --keep: marker AND persistence work together.
reset
export FAKE_STATE=""
out=$(cd "$TMP/proj" && RUN_WRAPPER --own-auth --keep 2>/dev/null | tail -1)
case "$out" in
    *"--name isoclaude-"*) ok "--own-auth + --keep both take effect" ;;
    *) bad "--own-auth + --keep" "got: $out" ;;
esac
[ -f "$TMP/proj/.isoclaude/local/own-auth" ] && ok "--own-auth + --keep still writes marker" \
    || bad "combined path skipped marker write"

# Credential isolation: OWN_AUTH=1 must overlay a per-project
# credentials file on the shared ~/.claude mount, seeded as {} so
# claude inside genuinely starts logged out.
reset
OWN_AUTH=1
RUN_FLAGS=()
compose_run_flags >/dev/null 2>&1 || true
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *"$TMP/proj/.isoclaude/local/credentials.json:/home/claude/.claude/.credentials.json"*) \
        ok "OWN_AUTH=1 overlays private credentials.json" ;;
    *) bad "no creds overlay" "flags: $flags" ;;
esac
[ -f "$TMP/proj/.isoclaude/local/credentials.json" ] \
    && ok "creds stub created on demand" || bad "creds stub missing"
[ "$(cat "$TMP/proj/.isoclaude/local/credentials.json")" = "{}" ] \
    && ok "creds stub is an empty JSON object" \
    || bad "stub content wrong" "got: $(cat "$TMP/proj/.isoclaude/local/credentials.json")"

# An existing (logged-in) creds file must NOT be overwritten by the stub.
reset
mkdir -p "$TMP/proj/.isoclaude/local"
printf '{"claudeAiOauth":{"accessToken":"container-token"}}\n' \
    > "$TMP/proj/.isoclaude/local/credentials.json"
OWN_AUTH=1
RUN_FLAGS=()
compose_run_flags >/dev/null 2>&1 || true
grep -q "container-token" "$TMP/proj/.isoclaude/local/credentials.json" \
    && ok "existing container tokens preserved (no re-seed)" \
    || bad "container tokens clobbered by stub"

# Control: OWN_AUTH=0 → no overlay, shared file untouched.
reset
OWN_AUTH=0
RUN_FLAGS=()
compose_run_flags >/dev/null 2>&1 || true
flags="${RUN_FLAGS[*]}"
case "$flags" in
    *":/home/claude/.claude/.credentials.json"*) bad "bridge mode emitted creds overlay" "flags: $flags" ;;
    *) ok "bridge mode has no creds overlay" ;;
esac

# cmd_sync_auth refuses when the marker exists.
reset
mkdir -p "$TMP/proj/.isoclaude/local"
: > "$TMP/proj/.isoclaude/local/own-auth"
# cmd_sync_auth calls die() which exits nonzero and prints to stderr.
# We can't run it directly in the same shell (would kill the test);
# invoke via subshell.
out=$( ( cd "$TMP/proj" && cmd_sync_auth ) 2>&1 || true )
case "$out" in
    *"own-auth mode"*"marker"*) ok "cmd_sync_auth refuses when marker exists" ;;
    *) bad "cmd_sync_auth clobbered without refusal" "got: $out" ;;
esac

# cmd_sync_auth --force bypasses the marker refusal.
reset
mkdir -p "$TMP/proj/.isoclaude/local"
: > "$TMP/proj/.isoclaude/local/own-auth"
out=$( ( cd "$TMP/proj" && cmd_sync_auth --force ) 2>&1 || true )
case "$out" in
    *"own-auth mode"*"marker"*) bad "--force did not bypass marker check" "got: $out" ;;
    *) ok "cmd_sync_auth --force bypasses marker check" ;;
esac

# _doctor_auth is marker-aware: reports own-auth mode instead of the
# "no host login found" advice.
reset
mkdir -p "$TMP/proj/.isoclaude/local"
: > "$TMP/proj/.isoclaude/local/own-auth"
out=$( ( cd "$TMP/proj" && _doctor_auth ) 2>&1 || true )
case "$out" in
    *"own-auth mode active"*|*"--own-auth mode active"*) ok "_doctor_auth reports own-auth mode when marker present" ;;
    *) bad "doctor missed the marker" "got: $out" ;;
esac
case "$out" in
    *"no host login found"*) bad "doctor still gave stale 'host login' advice" "got: $out" ;;
    *) ok "doctor suppresses irrelevant host-keychain diagnostics under own-auth" ;;
esac

# Help mentions --own-auth and its env var.
out="$(cmd_help)"
for tok in "--own-auth" "ISOCLAUDE_OWN_AUTH" "/login"; do
    case "$out" in
        *"$tok"*) ok "help mentions '$tok'" ;;
        *) bad "help missing '$tok'" ;;
    esac
done

#-----------------------------------------------------------------------
printf '\n\033[1mPhase 6: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
