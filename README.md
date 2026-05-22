# isoclaude

Run Claude Code in a container with your current working directory
mounted in, your auth and git config available, and nothing else from
your host exposed.

```sh
isoclaude            # claude with PWD as the sandbox
isoclaude --yolo     # skip permission prompts (the sandbox is the safety net)
isoclaude shell      # bash inside the sandbox, for ad-hoc work
```

## What you get inside the container

| Path | Mode | Notes |
|---|---|---|
| `$PWD` | rw | The directory you ran `isoclaude` from |
| `~/.claude` | rw | Your claude auth and history, so login persists |
| `~/.gitconfig` | ro | So commits inside have your name/email |
| `~/.ssh` | ro | So `git push` over SSH works |

Nothing else from your host filesystem is visible. Files you create
inside are owned by your host user (no root-owned junk).

Network egress is open — claude needs to reach Anthropic's API, and you
generally need `git pull`, `npm install`, etc., to work.

## Requirements

- macOS 15+ or Linux
- One container runtime, in this priority order:
  Apple [`container`](https://github.com/apple/container) →
  [OrbStack](https://orbstack.dev/) → Docker → Podman
- `npm` on the host (used once to discover the latest claude-code version
  during install; can be bypassed with `--version`)

## Quickstart

```sh
git clone https://github.com/yourname/iso_claude.git
cd iso_claude
./install.sh
isoclaude           # in any directory you want to work in
```

`install.sh` installs the wrapper to `~/.local/bin/isoclaude` (or
`/usr/local/bin` if that isn't writable), seeds `~/.isoclaude/` with the
base image files, pins the global claude version to npm latest, and
pre-builds the base image.

To install without the pre-build, or to pin to a specific version:
```sh
./install.sh --no-build --version 2.1.143
./install.sh --prefix /opt/isoclaude/bin
```

## How it works

A small bash wrapper builds and runs a Linux container with these flags:

- `-v $PWD:$PWD -w $PWD` — your working dir at the same path
- `-v ~/.claude:/home/claude/.claude` — auth persistence
- `-v ~/.gitconfig:...:ro`, `-v ~/.ssh:...:ro` — git tooling
- `-e HOST_UID -e HOST_GID` — for the entrypoint to remap the
  in-container user to match yours, so files you create are host-owned

The image is `debian:bookworm-slim` plus `node 22`, `git`, `gosu`, and a
pinned `claude-code` install. The entrypoint runs briefly as root to
adjust UIDs/GIDs (handling collisions with pre-existing groups like
`dialout`), then `exec gosu`s to a non-root `claude` user.

The claude version is recorded as an image label, so the wrapper
rebuilds automatically when you change your pin and never rebuilds when
nothing has changed.

## Subcommands

| Command | What it does |
|---|---|
| `isoclaude` | Launch claude (default action) |
| `isoclaude run [ARGS]` | Explicit form; ARGS go to claude |
| `isoclaude shell [ARGS]` | Launch bash in the sandbox |
| `isoclaude init` | Scaffold `.isoclaude/` in the current dir |
| `isoclaude build` | Force a rebuild of base + project images |
| `isoclaude version` | Show pins, image label, npm latest, project info |
| `isoclaude update [VER]` | Update global pin and rebuild |
| `isoclaude update --check` | Compare global pin to npm latest |
| `isoclaude pin [VER]` | Set per-project pin and rebuild |
| `isoclaude prune [--all]` | Remove built project images |
| `isoclaude doctor` | Diagnose runtime, image, auth, and project state. Exits 0 if no errors. |
| `isoclaude sync-auth` | macOS only — copy Claude Code's keychain credentials to `~/.claude/.credentials.json` so the in-container claude can authenticate. Each `run` and `shell` invocation also auto-refreshes silently when the keychain changes; you only need to call `sync-auth` explicitly to verify status. |
| `isoclaude uninstall [--purge]` | Remove the wrapper and config |
| `isoclaude help` | Show usage |

## Global flags

| Flag | Effect |
|---|---|
| `--yolo`, `-Y` | Pass `--dangerously-skip-permissions` to claude — the sandbox is the safety net, so it's reasonable to let claude work without per-tool confirmation. |
| `--` | Everything after is passed verbatim to claude |

Flags are order-independent: `isoclaude --yolo run --foo` and `isoclaude
run --yolo --foo` both work.

## Per-project config (`.isoclaude/`)

`isoclaude init` creates a `.isoclaude/` directory in the current
project with three optional config files. The wrapper walks up from your
PWD to find the nearest `.isoclaude/`, so config from a project root
applies even when you run `isoclaude` from a subdirectory.

```
.isoclaude/
├── Dockerfile        # optional: project image overlay
├── env               # KEY=VALUE lines injected as env vars
├── mounts            # extra bind mounts
├── claude-version    # per-project version pin (overrides global)
├── .gitignore        # excludes local/
└── local/            # gitignored per-developer overrides
    ├── env           # local env vars (override committed)
    └── mounts        # local mounts (added to committed)
```

### `Dockerfile`

Optional. Must `FROM isoclaude-base:latest`. The wrapper builds it on
demand, tagging the image by content hash so changes get a clean rebuild
and unchanged content reuses the cached image.

```dockerfile
FROM isoclaude-base:latest
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*
```

**Don't set `USER` in your project Dockerfile.** The base entrypoint
needs to run as root briefly to remap UIDs to your host, then drops to
the `claude` user via `gosu`. A `USER claude` line here would shift the
entrypoint to non-root and break the remap with "usermod: Permission
denied".

### `env`

```
# Comments and blanks are skipped.
DATABASE_URL=postgres://localhost/dev
LOG_LEVEL=debug
```

`local/env` is read after the committed `env` (so local values win in
the runtime).

### `mounts`

One bind-mount spec per line. `~` is expanded host-side. Format:
`/host/path:/container/path[:ro|:rw]`.

```
~/.cache/pip:/home/claude/.cache/pip
/opt/secrets:/secrets:ro
```

### MCP servers (auto-mount)

When the wrapper starts, it scans `.mcp.json` in the project root and the
`mcpServers` section of `~/.claude.json`. For each server whose
`command` is an absolute host path that exists, the wrapper bind-mounts
the command's parent dir into the container at the same path (`ro`), so
the in-container claude can spawn the same server as the host. Skipped
silently if the command is relative or non-existent; warned-and-skipped
if it lives under a system path that would shadow container
infrastructure (`/usr`, `/bin`, `/sbin`, `/lib*`, `/etc`, `/var`,
`/proc`, `/sys`, `/dev`). Paths already covered by `$PWD` or `~/.claude`
aren't re-mounted.

This is zero-configuration — typical macOS install locations like
`/opt/homebrew/...` and `/Users/<you>/...` Just Work. For MCP servers
that won't run cross-platform (Mach-O binaries on a macOS host with a
Linux container), claude inside fails per-server but the others keep
working.

### `claude-version`

```
2.1.143
```

A per-project pin overrides the global pin. Useful when a project needs
to stick to a specific claude version.

## Environment variables

| Variable | Effect |
|---|---|
| `ISOCLAUDE_HOME` | Override the install dir (default `~/.isoclaude`) |
| `ISOCLAUDE_RUNTIME` | Force a specific runtime (`docker`, `container`, etc.) |
| `ISOCLAUDE_BASE_IMAGE` | Override the base image tag |
| `ISOCLAUDE_DRY_RUN=1` | Print the runtime invocation instead of running |
| `ISOCLAUDE_YOLO=1` | Same as passing `--yolo` on every invocation |

## Updating

```sh
isoclaude update --check      # see if a newer claude is on npm
isoclaude update              # update global pin to npm latest, rebuild
isoclaude update 2.1.150      # pin to a specific version
isoclaude pin                 # lock current project to the current global pin
```

## Troubleshooting

**"no container runtime found"** — install one. On macOS:
```sh
brew install container && container system start --enable-kernel-install
```

**"dubious ownership in repository"** — already handled (the base image
sets `safe.directory = *` system-wide). If you still see this, rebuild:
`isoclaude build`.

**`-it` errors with `ENODEV`** — already handled (the wrapper only
requests `-t` when a TTY is actually present). If you pipe into
`isoclaude`, you'll see no TTY and that's correct.

**Image build is slow** — the base image build pulls debian + node 22 +
npm + claude-code. First build is a couple of minutes; subsequent
invocations reuse the cached image until your pin changes.

**Auth doesn't persist** — the wrapper mounts `~/.claude` rw, so a login
inside the container writes to the same dir as your host. If this stops
working, check that `~/.claude` is owned by your host user and not root.

**"Not logged in" on macOS even though host claude is logged in** — the
macOS native installer keeps OAuth credentials in the keychain, which the
Linux container can't reach. Run `isoclaude sync-auth` once (and again
after each host `/login`) to bridge the keychain into
`~/.claude/.credentials.json`, which the container can read. `install.sh`
does this automatically on macOS post-install.

## Uninstalling

```sh
isoclaude uninstall           # remove wrapper + ~/.isoclaude/, keep images
isoclaude uninstall --purge   # also remove all isoclaude-* images
isoclaude uninstall --yes     # skip the confirmation prompt
```

## Layout of the source tree

```
iso_claude/
├── bin/isoclaude         # the wrapper (bash, ~620 lines)
├── image/
│   ├── Dockerfile.base
│   └── entrypoint.sh
├── install.sh
├── tests/                # five test scripts, ~190 assertions
└── README.md
```

The `tests/` scripts are runnable directly. `test-phase1.sh` through
`test-phase5.sh` cover static + mocked behavior and run in seconds.
`test-live.sh` requires a real container runtime and exercises the image
end-to-end (UID remap, isolation, ro enforcement, signals, project
overlays).

## License

MIT.
