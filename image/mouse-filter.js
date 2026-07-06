#!/usr/bin/env node
// isoclaude mouse filter.
//
// Strips xterm mouse-tracking ENABLE sequences from a byte stream.
// claude-code's TUI turns on mouse reporting unconditionally
// (empirically: DISABLE_MOUSE=1 does not suppress it, probed v2.1.201).
// Once the host terminal sees these sequences it delivers every mouse
// drag to the app instead of selecting text, so copy/paste dies — in
// tmux and out of it. Filtering the enable sequences here means the
// terminal never turns mouse reporting on, drag-to-select keeps
// working, and claude simply never receives mouse events (it degrades
// gracefully, same as on a terminal without mouse support).
//
// Only the ENABLE (`h`) forms are stripped. DISABLE (`l`) forms pass
// through: disabling a mode that was never enabled is a harmless no-op,
// and passing them means a mode enabled by something *else* in the
// stream's past still gets cleaned up on exit.
//
// Alt-screen (?1049), bracketed paste (?2004), focus events (?1004) and
// cursor visibility are left alone — they don't break host selection.

'use strict';

const TARGETS = ['1000', '1002', '1003', '1005', '1006', '1015']
    .map((n) => Buffer.from(`\x1b[?${n}h`, 'latin1'));
const MAXLEN = TARGETS.reduce((m, t) => Math.max(m, t.length), 0);

// Longest suffix of `buf` that is a proper prefix of any target
// sequence. That suffix must be held back until the next chunk decides
// whether it completes a target.
function partialSuffixLen(buf) {
    const max = Math.min(buf.length, MAXLEN - 1);
    for (let len = max; len > 0; len--) {
        const tail = buf.subarray(buf.length - len);
        for (const t of TARGETS) {
            if (t.subarray(0, len).equals(tail)) return len;
        }
    }
    return 0;
}

// Remove every complete target occurrence from `buf`.
function stripTargets(buf) {
    const out = [];
    let i = 0;
    scan: while (i < buf.length) {
        if (buf[i] === 0x1b) {
            for (const t of TARGETS) {
                if (i + t.length <= buf.length && buf.subarray(i, i + t.length).equals(t)) {
                    i += t.length;
                    continue scan;
                }
            }
        }
        let j = buf.indexOf(0x1b, i + 1);
        if (j === -1) j = buf.length;
        out.push(buf.subarray(i, j));
        i = j;
    }
    return out.length === 1 ? out[0] : Buffer.concat(out);
}

let carry = Buffer.alloc(0);

process.stdin.on('data', (chunk) => {
    const buf = carry.length ? Buffer.concat([carry, chunk]) : chunk;
    const stripped = stripTargets(buf);
    const hold = partialSuffixLen(stripped);
    if (hold > 0) {
        carry = Buffer.from(stripped.subarray(stripped.length - hold));
        if (stripped.length > hold) {
            process.stdout.write(stripped.subarray(0, stripped.length - hold));
        }
    } else {
        carry = Buffer.alloc(0);
        if (stripped.length) process.stdout.write(stripped);
    }
});

process.stdin.on('end', () => {
    if (carry.length) process.stdout.write(carry);
    process.exit(0);
});

// If the terminal side goes away first, exit quietly instead of
// throwing EPIPE.
process.stdout.on('error', () => process.exit(0));
