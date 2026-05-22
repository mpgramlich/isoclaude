# isoclaude

Run Claude Code in a sandboxed Linux container. Your current working
directory is mounted in, your auth and git config travel with you,
nothing else from your host is exposed.

```sh
isoclaude            # claude with $PWD as the sandbox
isoclaude --yolo     # skip permission prompts (the sandbox is the safety net)
isoclaude shell      # bash inside the sandbox, for ad-hoc work
```

The `claude` user inside has passwordless `sudo`, so `sudo apt-get
install …` and `sudo npm install -g …` just work — useful for adding
tools or MCP servers without leaving the container.

## What you get inside the container

| Path | Mode | Notes |
|---|---|---|
| `$PWD` | rw | The directory you ran `isoclaude` from |
| `~/.claude` | rw | Claude auth and session history; login persists |
| `~/.claude.json` | rw | Claude config |
| `~/.gitconfig` | ro | So commits inside have your name/email |
| `~/.ssh` | ro | So `git push` over SSH works |

Nothing else from your host filesystem is visible. Files created inside
are owned by your host user (no root-owned junk). Network egress is open.

## Requirements

- macOS 15+ or Linux
- One container runtime — wrapper looks for these in order:
  Apple [`container`](https://github.com/apple/container) →
  [OrbStack](https://orbstack.dev/) → Docker → Podman
- `npm` on the host (used once to discover the latest claude-code
  version during install; bypass with `--version`)

## Install

```sh
git clone https://github.com/yourname/iso_claude.git
cd iso_claude
./install.sh
isoclaude          # from any directory now
```

`install.sh` installs the wrapper to `~/.local/bin/isoclaude` (or
`/usr/local/bin` if that isn't writable), seeds `~/.isoclaude/` with the
image files, writes the global claude version pin from npm latest, and
pre-builds the base image. On macOS it also runs `sync-auth` if you're
logged in via the native installer (see Troubleshooting).

```sh
./install.sh --no-build --version 2.1.143    # skip pre-build, pin to a specific version
./install.sh --prefix /opt/isoclaude/bin     # custom prefix
./install.sh --force                          # overwrite an existing install
```

## How it works

The wrapper builds a Linux container from `debian:trixie-slim` plus
node 22, git, gosu, sudo, and a pinned `claude-code` install. On every
invocation it:

1. Detects a runtime (`container` → `orb` → `docker` → `podman`)
2. Walks up from `$PWD` to find any `.isoclaude/` (project config)
3. Reads the version pin (project > global > npm latest)
4. Builds the base image if the pin doesn't match the image label
5. Builds a project image (if `.isoclaude/Dockerfile` exists) tagged by
   content hash, so edits trigger one rebuild and unchanged content
   reuses the cache
6. Composes `docker run` args (mounts, env, UID/GID, tty handling)
7. `exec`s the runtime — entrypoint briefly runs as root to remap the
   in-container `claude` user's UID/GID to match yours, then drops to
   the non-root `claude` user via `gosu`

The claude version is stored as an image label, so the wrapper
rebuilds when you change your pin and never rebuilds when it doesn't
have to.

## Subcommands

| Command | What it does |
|---|---|
| `isoclaude` | Launch claude (default action) |
| `isoclaude run [ARGS]` | Explicit form; `ARGS` go to claude |
| `isoclaude shell [ARGS]` | Launch bash in the sandbox |
| `isoclaude init` | Scaffold `.isoclaude/` in the current dir |
| `isoclaude build` | Force-rebuild the base (and project) image |
| `isoclaude version` | Pins, image label, npm latest, project info |
| `isoclaude update [VER]` | Update global pin and rebuild |
| `isoclaude update --check` | Compare global pin to npm latest, no changes |
| `isoclaude pin [VER]` | Set per-project pin and rebuild |
| `isoclaude prune [--all]` | Remove built project images (keeps current unless `--all`) |
| `isoclaude doctor` | Diagnose runtime / image / auth / project state; exits 0 if no errors |
| `isoclaude sync-auth` | macOS only: bridge keychain creds to `~/.claude/.credentials.json` |
| `isoclaude uninstall [--purge] [--yes]` | Remove wrapper and config (`--purge` also nukes images) |
| `isoclaude help` | Show usage |

## Global flags

| Flag | Effect |
|---|---|
| `--yolo`, `-Y` | Pass `--dangerously-skip-permissions` to claude — the sandbox is the safety net |
| `--` | Everything after is a literal claude arg |

Order-independent up to `--`: `isoclaude --yolo run --foo` and
`isoclaude run --yolo --foo` both pass `--dangerously-skip-permissions
--foo` to claude. After `--`, the wrapper stops interpreting flags so
you can pass a literal `--yolo` if you ever need to.

## Per-project config (`.isoclaude/`)

`isoclaude init` scaffolds `.isoclaude/` in the current directory. The
wrapper walks up from `$PWD` to find the nearest one, so config from a
project root applies even when you run from a subdirectory.

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
demand and tags it by content hash, so identical content reuses the
cached image and every edit triggers exactly one rebuild.

```dockerfile
FROM isoclaude-base:latest
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*
```

**Don't set `USER` in your project Dockerfile.** The base entrypoint
needs to run as root briefly to remap UIDs to your host, then drops to
the `claude` user via `gosu`. A `USER claude` line here would shift
the entrypoint to non-root and break the remap with "usermod:
Permission denied".

### `env`

```
# Comments and blanks are skipped. Malformed lines (no `=`, empty key)
# get a warning on stderr and are skipped — they won't crash the run.
DATABASE_URL=postgres://localhost/dev
LOG_LEVEL=debug
```

`local/env` is read after the committed `env`, so local values override
committed ones at runtime.

### `mounts`

One bind-mount spec per line. `~` is expanded host-side. Format:
`/host/path:/container/path[:ro|:rw]`.

```
~/.cache/pip:/home/claude/.cache/pip
/opt/secrets:/secrets:ro
```

Host paths that don't exist get a warning and are skipped (instead of
producing a cryptic runtime error).

### Plugins (per-project isolation)

When the wrapper detects a project root (anywhere with a `.isoclaude/`
walking up from PWD), it mounts `<project>/.isoclaude/local/plugins`
over the in-container `~/.claude/plugins`, so each project has its own
plugin set:

- Plugin installed in project A → only project A sees it.
- The host's `~/.claude/plugins` is hidden from inside, so the
  in-container claude doesn't pick up unrelated host plugins.
- Plugins persist on the host at `<project>/.isoclaude/local/plugins/`
  (gitignored via `local/` so they don't get committed).

As a reference, the host's plugins are also re-mounted **read-only** at
`~/.claude/host-plugins` inside the container — useful when you want to
copy a plugin in from your host setup:

```sh
# inside the sandbox
cp -r ~/.claude/host-plugins/marketplaces/some-plugin ~/.claude/plugins/marketplaces/
```

Without a `.isoclaude/` (ad-hoc usage), no override happens and the
host's plugins are visible as usual.

### MCP servers

The container is self-contained. If a project needs an MCP server,
install it inside the container — the simplest way is `.isoclaude/Dockerfile`:

```dockerfile
FROM isoclaude-base:latest
RUN npm install -g @some-org/some-mcp-server
# or: RUN apt-get update && apt-get install -y some-mcp-server-pkg
```

For an ad-hoc install at runtime, claude inside can `sudo apt-get
install …` or `sudo npm install -g …` directly. For the rare case
where you want to bind in a cross-platform host script, list its
directory in `.isoclaude/mounts`.

### `claude-version`

```
2.1.143
```

A per-project pin overrides the global pin. Useful when a project
needs to stick to a specific claude version.

## Environment variables

| Variable | Effect |
|---|---|
| `ISOCLAUDE_HOME` | Override the install dir (default `~/.isoclaude`) |
| `ISOCLAUDE_RUNTIME` | Force a specific runtime (`docker`, `container`, etc.) |
| `ISOCLAUDE_BASE_IMAGE` | Override the base image tag |
| `ISOCLAUDE_DRY_RUN=1` | Print the runtime invocation instead of running |
| `ISOCLAUDE_YOLO=1` | Same as passing `--yolo` on every invocation |

## Updating claude inside the sandbox

```sh
isoclaude update --check      # is a newer claude on npm?
isoclaude update              # bump global pin to npm latest, rebuild
isoclaude update 2.1.150      # pin to a specific version
isoclaude pin                 # lock current project to the current global pin
isoclaude pin 2.1.143         # lock current project to a specific version
```

## Troubleshooting

**`isoclaude doctor`** is the fastest way to find a broken setup —
it reports runtime, wrapper location, pin/image consistency, auth
state, and project config. Exits 0 if nothing's broken.

**"no container runtime found"** — install one. On macOS:
```sh
brew install container && container system start --enable-kernel-install
```

**"dubious ownership in repository"** — already handled (the base
image sets `safe.directory = *` system-wide). If you still see it,
rebuild: `isoclaude build`.

**`-it` errors with `ENODEV`** — already handled (`-t` is only
requested when stdout is a real TTY).

**Image build is slow** — first build pulls debian + node 22 + claude-
code, which is a couple of minutes. Subsequent runs reuse the cached
image until your pin or the Dockerfile changes.

**Auth doesn't persist** — the wrapper mounts `~/.claude` rw, so a
login inside writes to the host. If this stops working, check that
`~/.claude` is owned by your host user.

**"Not logged in" on macOS even though host claude is logged in** —
the macOS native installer keeps OAuth credentials in the keychain,
which Linux containers can't reach. Run `isoclaude sync-auth` once
to bridge the keychain into `~/.claude/.credentials.json`. After
that, every `run`/`shell` invocation silently re-syncs when the
keychain content changes. `install.sh` runs this automatically post-
install when applicable.

## Uninstalling

```sh
isoclaude uninstall           # remove wrapper + ~/.isoclaude/, keep images
isoclaude uninstall --purge   # also remove all isoclaude-* images
isoclaude uninstall --yes     # skip the confirmation prompt
```

## Source layout

```
iso_claude/
├── bin/isoclaude          # the wrapper (bash, ~1k lines)
├── image/
│   ├── Dockerfile.base    # debian:trixie + node + git + gosu + sudo + claude-code
│   └── entrypoint.sh      # UID/GID remap + drop to non-root claude
├── install.sh             # install to ~/.local/bin or --prefix
├── tests/
│   ├── test-phase1.sh     # base image (33 assertions)
│   ├── test-phase2.sh     # wrapper core (53 assertions)
│   ├── test-phase3.sh     # subcommands + dispatcher (60 assertions)
│   ├── test-phase4.sh     # project overlays (32 assertions)
│   ├── test-phase5.sh     # installer + prune + uninstall + doctor (65 assertions)
│   └── test-live.sh       # end-to-end against a real runtime (17 assertions)
├── COLDSTART.md           # contributor onboarding
└── README.md              # this file
```

243 mocked + 17 live = **260 assertions**, all pass on macOS 15+ with
Apple `container` 0.12+. See [COLDSTART.md](COLDSTART.md) if you want
to contribute or just understand the internals.

## License

MIT — see `LICENSE`.
