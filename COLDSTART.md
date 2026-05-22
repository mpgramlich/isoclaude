# COLDSTART

Contributor onboarding. The README is for people *using* isoclaude;
this one is for people changing it.

## Tour of the repo

| Path | What it is |
|---|---|
| `bin/isoclaude` | The wrapper. One ~1k-line bash script. **All of the runtime logic lives here.** |
| `image/Dockerfile.base` | The base image (debian:trixie-slim + node 22 + git + gosu + sudo + claude-code). |
| `image/entrypoint.sh` | Runs as root inside the container, remaps the in-image `claude` user's UID/GID to match the host, drops to that user via gosu. |
| `install.sh` | Bash installer. Copies wrapper to `~/.local/bin`, seeds `~/.isoclaude/`, optionally pre-builds. |
| `tests/test-phase{1..5}.sh` | Static + mocked tests, one per implementation phase. Each is self-contained and runnable directly. |
| `tests/test-live.sh` | End-to-end against a real container runtime. Skip-gracefully if no runtime is on `PATH`. |
| `README.md` | User-facing reference. |
| `COLDSTART.md` | This file. |

No build system, no package manager, no language runtime needed to
contribute — bash on the host, bash + docker-compatible runtime to
test live, python3 for one JSON-parsing helper. That's it.

## Running tests

There are six test scripts. Every one is a plain bash script that
prints `ok` / `FAIL` lines and a summary, exits 0 iff all checks pass.

```sh
tests/test-phase1.sh         # ~3s  — image structure, entrypoint behavior, optional live build
tests/test-phase2.sh         # ~1s  — wrapper core, runtime detect, project_root, etc.
tests/test-phase3.sh         # ~5s  — dispatcher, every subcommand against a fake runtime
tests/test-phase4.sh         # ~1s  — project overlays (env, mounts, project Dockerfile)
tests/test-phase5.sh         # ~3s  — install.sh, prune, uninstall, sync-auth, doctor
tests/test-live.sh           # ~30s — needs a real runtime; covers UID remap, isolation, signals, project overlays, sudo
```

Run them all in one go (this is how the project gets verified):

```sh
for t in tests/test-phase*.sh; do
    printf '%-30s ' "$t"
    bash "$t" 2>&1 | tail -1
done
tests/test-live.sh 2>&1 | tail -3
```

Expected: 243 mocked assertions + 17 live assertions, all `0 failed`.

### Running tests *inside* isoclaude itself

This is the dogfood loop. From the repo:

```sh
./bin/isoclaude shell -c 'for t in tests/test-phase*.sh; do printf "%-30s " "$t"; bash $t 2>&1 | tail -1; done'
```

The static + mocked suites all pass inside the container (no runtime
needed there). `test-live.sh` won't work inside because there's no
container-in-container.

This is how new features get verified end-to-end before shipping —
edit the wrapper on the host, run the test suite from inside the
sandbox, ship the change. The repo's own `bin/isoclaude` is auto-
synced into `~/.isoclaude/` by the wrapper's content-diff sync
(`_sync_if_diff`), so edits to `image/Dockerfile.base` and
`image/entrypoint.sh` are picked up by the next `isoclaude build`
without re-installing.

## Wrapper architecture

`bin/isoclaude` is one bash script. Key parts in roughly the order
they appear:

```
constants            ISOCLAUDE_HOME, ISOCLAUDE_BASE_IMAGE, NPM_PACKAGE
logging              log / warn / die — all to stderr
discovery            detect_runtime, project_root, _self_path
state                ensure_iso_home (sync from repo if dev mode),
                     read_pin (project > global > npm latest)
image management     image_label_version (JSON parse, runtime-agnostic),
                     ensure_base_image (rebuild when label drifts),
                     ensure_project_image (FROM check, hash-tagged),
                     _file_hash
auth                 _macos_auth_refresh (keychain → file, atomic),
                     _macos_auth_check (wrapper used in compose),
                     cmd_sync_auth (explicit subcommand)
flags                _add (RUN_FLAGS), _add_mount,
                     compose_run_flags (the meat),
                     _add_project_env, _add_project_mounts
exec                 _exec_in_sandbox (chooses RUN_IMAGE; honors DRY_RUN),
                     _prepare (pulls everything together)
subcommands          cmd_run, cmd_shell, cmd_init, cmd_build,
                     cmd_version, cmd_update, cmd_pin, cmd_prune,
                     cmd_uninstall, cmd_help, cmd_doctor
doctor               _doc_* helpers (status indicators, counters),
                     _doctor_* sections (runtime, wrapper, pin/image,
                     auth, project), cmd_doctor (orchestrator)
dispatcher           main() — strips --yolo/-Y (respects --),
                     routes to cmd_*, falls through to cmd_run
sourceability        `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main`
                     guard so tests can source the script without
                     running it
```

A few design choices that are load-bearing:

- **Bash 3.2 compatible.** macOS ships bash 3.2; we don't want to
  require homebrew bash. No `mapfile`/`readarray`, no `${arr[@]:0:N}`
  slicing, no associative arrays, no `&>` redirection. The Phase 2
  test enforces this with `code_only | grep -q '\bmapfile\b'`.
- **`set -eo pipefail`, no `-u`.** `-u` interacts poorly with bash
  3.2's empty-array handling. Many functions explicitly `return 0`
  to keep `set -e` from firing when the last statement happened to
  return non-zero (`[ … ] && log "…"` is a classic offender).
- **JSON via python3, not jq.** python3 is always on macOS; jq isn't.
  Used in `image_label_version` (runtime-agnostic label extraction)
  and was used in the now-removed MCP auto-mount.
- **stdout vs stderr.** All `log`/`warn`/`die` go to stderr so users
  can pipe wrapper stdout cleanly (`isoclaude run -p "…" | grep …`).
  The Phase 5 dogfood scenario verifies this.
- **stdin handling for claude inside.** `compose_run_flags` passes
  `-i` only when stdin is a TTY, pipe, or non-empty regular file. If
  stdin is `/dev/null` or a socket (background subprocess), `-i`
  isn't passed — otherwise claude inside waits 3s for input that
  never comes. `-t` is gated on stdout being a TTY because Apple
  `container` errors with `ENODEV` if you request it without one.
- **Image tagging.** The base image is `isoclaude-base:latest` and
  carries the claude version as a `LABEL`, so the wrapper can detect
  pin/label drift without rebuilding. Project images are
  `isoclaude-project-<sha-first-12>:latest` — content hash in the
  tag, so identical content reuses the image.
- **UID/GID remap.** The image bakes a `claude` user at UID/GID
  1000:1000. The entrypoint adjusts those to match `$HOST_UID` /
  `$HOST_GID` *before* dropping privileges, so files bind-mounted in
  appear with the right owner and files created inside end up host-
  owned on the way out. Collisions with pre-existing container
  groups (debian's `dialout` at GID 20) are handled by reassigning
  via `usermod -g` rather than failing on `groupmod`.

## Image and entrypoint

The base `Dockerfile.base` is intentionally minimal:

- `FROM debian:trixie-slim`
- apt install: ca-certificates, curl, git, gosu, gnupg, openssh-client, sudo, nodejs (via nodesource setup_22.x)
- npm install -g the pinned `@anthropic-ai/claude-code`
- `useradd claude` at 1000:1000
- passwordless sudoers rule (`claude ALL=(ALL) NOPASSWD: ALL`)
- system git `safe.directory = *` (the bind mount root often looks root-owned to git)
- entrypoint script
- `LABEL isoclaude.claude_version=$CLAUDE_VERSION`

The `entrypoint.sh` is small and only does three things:

1. Remap the `claude` group's GID to `$HOST_GID` (uses `usermod -g`
   into an existing group if a collision exists)
2. Remap the user's UID to `$HOST_UID`
3. chown `/home/claude` (skipping bind-mounted paths) so dotfiles
   match the new UID
4. `exec gosu claude "$@"`

That's it. Don't grow it without good reason — the more code runs as
root, the more surface area there is.

## Dispatching a new subcommand

Three places to touch:

```bash
# 1. Add a cmd_X function next to the others in bin/isoclaude:
cmd_X() {
    _prepare           # call this if X needs a runtime / image
    # … do work, write to stderr via log/warn/die, exit 1 to fail
}

# 2. Wire it into main()'s case:
case "${1:-}" in
    …
    X)              shift; cmd_X "$@" ;;
    …
esac

# 3. Document it in cmd_help's heredoc.
```

Then in `tests/test-phase3.sh`, add an assertion that hits the new
dispatcher branch. If `cmd_X` has its own logic worth unit-testing,
add a section that calls it directly under a mocked HOME/runtime
(test-phase3 already sets up everything needed — copy a section).

## Dispatching a new config file

`.isoclaude/<your-thing>` is the natural place. The convention so
far:

- Read in `compose_run_flags` after the existing project blocks.
- Provide a `_add_<your_thing>` helper that takes a path and is a
  no-op when the file doesn't exist.
- Support a `local/<your-thing>` overlay if it makes sense — local
  is read second so its values override.
- Skip blanks and comments, warn loudly (and skip) on malformed
  lines — don't crash the run.

Look at `_add_project_env` and `_add_project_mounts` for the pattern.

## The dogfood loop (how you'll actually develop)

Most changes look like:

1. Edit `bin/isoclaude`, `image/*`, or one of the test scripts on the
   host with your normal editor.
2. Run the test suites from inside isoclaude:
   ```sh
   ./bin/isoclaude shell -c 'bash tests/test-phaseN.sh 2>&1 | tail -5'
   ```
3. For changes that touch the image: `./bin/isoclaude build` first.
   The wrapper auto-syncs `image/Dockerfile.base` and
   `image/entrypoint.sh` from the repo into `~/.isoclaude/` before
   building, so you don't have to re-install.
4. For live verification: `tests/test-live.sh` (host-side, needs a
   runtime).
5. When green, commit with a `Co-Authored-By: Claude` trailer if
   claude helped, and a clear "why" in the message.

The full dogfood loop (driving claude *inside* the container to test
real workflows) is documented in commit history — see commits with
"dogfood" in the message. Most of the wrapper's edge-case fixes
(`-i` gate, PWD=`:`, `~/.claude` auto-create, etc.) were surfaced this
way.

## Known sharp edges

- **bash 3.2 `set -e` + return-value functions.** If `func` returns
  1 and the next line tries to read `$?`, `set -e` fires first.
  Wrap it: `local rc=0; func || rc=$?; case "$rc" in …`. See
  `_macos_auth_check` for the canonical example.
- **`$()` runs in a subshell.** `out=$(func_that_sets_RUN_FLAGS)`
  doesn't update the parent's `RUN_FLAGS`. If you want the side-
  effect, redirect stderr to a file (`func 2>"$tmp.err"`) and let
  the function run in-process.
- **Apple `container` quirks.** `-it` without a TTY → `ENODEV`.
  `image inspect --format` not supported (we parse JSON). `-v` and
  `--mount` syntaxes both work despite the help only documenting
  `--mount`.
- **PWD with `:`.** Refused — the `-v src:dst` syntax has nowhere to
  go. A move to `--mount type=bind,source=…,target=…` would lift
  this; deferred because colons in paths are uncommon.
- **MCP server commands referencing host paths.** No auto-mount.
  Install the server inside the container with `.isoclaude/Dockerfile`
  or, for a one-off cross-platform host script, list the dir in
  `.isoclaude/mounts`.

## Style

- Two spaces of indent in bash, but match surrounding files.
- Function names: lowercase, snake_case. `_` prefix marks "private"
  helpers; commands are `cmd_<name>`.
- No comments that just restate the code. Do leave a comment when
  the *why* isn't obvious — workarounds, runtime quirks, design
  trade-offs. There are several in the wrapper that explain why
  things are the shape they are; preserve and add to them.
- Tests are bash scripts that print `ok`/`FAIL` lines. No frameworks.
  Group with `section "name"`. Use `case "$x" in …` rather than
  `[[ … ]]` so things stay bash 3.2-friendly.

## How releases / upgrades work

There aren't any (no published image, no homebrew tap). Right now
"shipping" is `git push`. Users update by `git pull && ./install.sh
--force`. The version pin (separate from the wrapper version) is
managed via `isoclaude update`.

If we ever cut versioned releases:

- Tag the commit. Bump a `VERSION` constant in the wrapper.
- The base image label is keyed off claude's version, not isoclaude's,
  so users don't get spurious rebuilds when the wrapper changes.

## When in doubt

Read `bin/isoclaude` end-to-end. It's deliberately one file. The
inline comments explain the load-bearing decisions; the surrounding
code is mostly straightforward bash. If you can read 1k lines of
shell, you can change anything in here.
