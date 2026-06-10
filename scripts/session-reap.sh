#!/usr/bin/env bash
#
# session-reap.sh — remove stale per-session mode files from
#                   ${STATE_DIR}/session/<uuid>
#
# A session file is stale when its UUID is NOT present in the process table
# (no live `claude ... --session-id <uuid>` process).
#
# TOCTOU grace-window: only reap files older than 60 seconds.  A session
# that is starting mid-reap will have a file that is ≤60s old; we leave it.
# A dead session's file will be >60s old once the process has gone.
#
# Live-set derivation: parse `ps -eo command` for `--session-id <uuid>`.
# This is the process table — not transcripts, not socket files — so it is
# authoritative for running processes.
#
# Idempotent: a second run on the same state is a no-op (exit 0).
#

# Resolve symlinks to find the real script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# Load lib-mode.sh for _validate_session_id
STATE_DIR="${CLAUDE_REMOTE_STATE_DIR:-$HOME/.claude-remote}"
source "$SCRIPT_DIR/lib-mode.sh" 2>/dev/null || {
    echo "session-reap: lib-mode.sh not found, skipping" >&2
    exit 0
}

SESSION_DIR="${STATE_DIR}/session"

# Nothing to do if no session directory
if [[ ! -d "$SESSION_DIR" ]]; then
    exit 0
fi

GRACE_SECONDS=60

# Build the live set: UUIDs of running claude processes
# ps -eo command prints one line per process with the full command string.
# We extract every --session-id argument that looks like a UUID.
# Indirection: CLAUDE_REMOTE_PS_BIN lets tests stub ps.
PS_BIN="${CLAUDE_REMOTE_PS_BIN:-ps}"

live_ids=""
while IFS= read -r cmdline; do
    # Extract value after --session-id (next word)
    if [[ "$cmdline" =~ --session-id[[:space:]]+([^[:space:]]+) ]]; then
        candidate="${BASH_REMATCH[1]}"
        if _validate_session_id "$candidate"; then
            live_ids="${live_ids}${candidate}"$'\n'
        fi
    fi
done < <("$PS_BIN" -eo command 2>/dev/null)

reaped=0
now="$(date +%s)"

for sf in "$SESSION_DIR"/*; do
    [[ -f "$sf" ]] || continue

    fname="$(basename "$sf")"

    # Skip malformed filenames (not UUIDs) — should never exist but be safe
    if ! _validate_session_id "$fname"; then
        echo "session-reap: skipping non-UUID file '${fname}'" >&2
        continue
    fi

    # Grace-window: skip files younger than GRACE_SECONDS
    # Use stat -f %m (macOS) with fallback to stat -c %Y (Linux)
    if mtime=$(stat -f %m "$sf" 2>/dev/null) || mtime=$(stat -c %Y "$sf" 2>/dev/null); then
        age=$(( now - mtime ))
        if (( age < GRACE_SECONDS )); then
            continue
        fi
    fi

    # Check if this id is in the live set
    if printf '%s' "$live_ids" | grep -qxF "$fname"; then
        : # live session — leave it
    else
        rm -f "$sf"
        echo "session-reap: removed stale session file ${fname}"
        reaped=$(( reaped + 1 ))
    fi
done

echo "session-reap: done (reaped ${reaped} session file(s))"
exit 0
