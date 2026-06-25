#!/usr/bin/env bash
#
# session-reap.sh — remove stale per-session mode files from
#                   ${STATE_DIR}/session/<uuid>
#
# Liveness signal — why a PID, not the UUID:
#   Each session file is keyed by the session UUID, which the writer
#   (toggle.sh) reads from $CLAUDE_CODE_SESSION_ID in its environment. The
#   reaper cannot observe that UUID at reap time: on macOS the session-launcher
#   process ("claude --agent lead …") carries the UUID in NEITHER its argv NOR
#   its `ps eww` environment, so any argv/env-scraping live-set is empty for
#   normally-launched sessions — and the reaper then deletes the ACTIVE
#   session's file, silently reverting offload to local mid-session.
#
#   Instead, the writer records a liveness token the reaper CAN observe: the OS
#   pid of the long-lived `claude`/`node` process that owns the session
#   (see _session_owner_pid in lib-mode.sh). This file holds:
#       line 1: mode  (on|off)        — read by lib-mode.sh
#       line 2: pid:<owner>           — read here; the liveness token
#   A session is LIVE iff `kill -0 <owner>` succeeds. This is UUID-independent
#   and ps-format-independent.
#
# TOCTOU grace-window: only reap files older than 60 seconds. This is a
#   SECONDARY guard for the narrow race where a file is written mid-reap (its
#   owner pid not yet flushed, or the file just created). Primary protection for
#   live sessions is the kill -0 check, not the age.
#
# Legacy files: files with no "pid:" line (written before this fix) have no
#   observable owner, so they are treated as dead candidates and reaped once
#   past the grace window. This is correct — they are genuine orphans.
#
# macOS/Linux: mtime via stat -f %m (macOS) with fallback to stat -c %Y (Linux).
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

# _owner_pid_of <file> — print the owner pid recorded on line 2 ("pid:<n>"),
# or nothing if absent/malformed. Only the FIRST pid: line is honoured.
_owner_pid_of() {
    local f="$1" line pid=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^pid:([0-9]+)$ ]]; then
            pid="${BASH_REMATCH[1]}"
            break
        fi
    done < "$f"
    printf '%s' "$pid"
}

# _owner_alive <file> — exit 0 if the file records a live owner pid, 1 otherwise.
# No pid line, malformed pid, or a dead pid → not alive (1).
_owner_alive() {
    local pid
    pid="$(_owner_pid_of "$1")"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

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

    # Primary liveness check: owner process still running → keep, regardless of age.
    if _owner_alive "$sf"; then
        continue
    fi

    # Owner is dead or unknown. Apply the TOCTOU grace-window: skip files
    # younger than GRACE_SECONDS (just-written file whose owner token may not be
    # flushed yet, or a session starting mid-reap).
    if mtime=$(stat -f %m "$sf" 2>/dev/null) || mtime=$(stat -c %Y "$sf" 2>/dev/null); then
        age=$(( now - mtime ))
        if (( age < GRACE_SECONDS )); then
            continue
        fi
    fi

    rm -f "$sf"
    echo "session-reap: removed stale session file ${fname}"
    reaped=$(( reaped + 1 ))
done

echo "session-reap: done (reaped ${reaped} session file(s))"
exit 0
