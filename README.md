# isoclaude

Run Claude Code in a container with your current working directory mounted
in, your auth and git config available, and nothing else from your host
exposed.

## Status

In development. Currently implemented:

- Phase 1: base image (Dockerfile + entrypoint with UID/GID remap)
- Phase 2: wrapper core (`isoclaude` default run path)

Not yet implemented: subcommands (`init`, `update`, `pin`, `version`, `shell`,
`build`), project-level `.isoclaude/` config overlays, installer.

## Quickstart (after install)

```sh
isoclaude            # launch claude in a sandbox, pwd mounted
```

Inside the container:

- `$PWD` is read/write
- `~/.claude` is read/write (so login persists)
- `~/.gitconfig` and `~/.ssh` are read-only
- Network egress is open
- Files you create are owned by your host user

Nothing else from your host is visible.

## Requirements

- One of: Docker, Podman, OrbStack (`orb`), or Apple `container`
- `npm` on the host (used once to discover the latest Claude Code version)

## How it works

A small bash wrapper invokes your container runtime with a curated set of
bind mounts and an entrypoint that remaps the in-container user's UID/GID to
match yours. The image installs a pinned version of Claude Code; rebuilds
happen automatically when the pin changes.

See the implementation plan in commit history for the full design.
