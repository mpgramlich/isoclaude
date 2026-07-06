#!/usr/bin/env bash
# isoclaude pty filter wrapper.
#
# Runs "$@" under a pty (via util-linux script(1)) so the child still
# believes it has a TTY and renders its full TUI, while piping the
# output through mouse-filter.js to strip the mouse-tracking enable
# sequences that break host-terminal text selection.
#
# stdin flows: terminal → script's pty master → child.
# stdout flows: child → pty → script → mouse-filter → terminal.
# script(1) forwards SIGWINCH, so resizes propagate to the child.

set -o pipefail

# script(1) runs the -c command via $SHELL; force bash so the %q-quoted
# argv below is parsed by the shell that produced it (dash chokes on
# bash's $'...' quoting form).
export SHELL=/bin/bash

cmd=""
for a in "$@"; do
    cmd+="$(printf ' %q' "$a")"
done

script -qefc "${cmd# }" /dev/null | node /usr/local/lib/isoclaude/mouse-filter.js
exit "${PIPESTATUS[0]}"
