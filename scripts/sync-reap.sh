#!/usr/bin/env bash
#
# Reap zombie Mutagen sync sessions created by claude-remote.
# A session is a zombie if:
#   - Its status is Halted, Disconnected, or contains "error" (case-insensitive), OR
#   - Its alpha (local) path no longer exists on disk.
#
# Second pass: reap stale per-session mode files (session-reap.sh).
#
# Idempotent. Exits 0 even if mutagen is absent or the daemon is down.
#

# Resolve symlinks to find the real script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# If mutagen is not installed, nothing to do.
command -v mutagen >/dev/null 2>&1 || { "$SCRIPT_DIR/session-reap.sh"; exit 0; }

# If the mutagen daemon is not running, skip mutagen pass but still run session-reap.
mutagen daemon list >/dev/null 2>&1 || { "$SCRIPT_DIR/session-reap.sh"; exit 0; }

# Collect all claude-remote session names.
# `mutagen sync list` output format (simplified):
#   Name: claude-remote-...
#   ...
#   Status: Watching for changes
#   Alpha:
#     URL: /some/local/path
session_list=$(mutagen sync list --label-selector=name=claude-remote 2>/dev/null) || exit 0

if [[ -z "$session_list" ]]; then
    echo "sync-reap: no claude-remote sessions found"
    exit 0
fi

reaped=0

# Parse out blocks per session. Each session block ends before the next "Name:" line
# or at EOF.  We walk the output line-by-line and act when we have enough info.
current_name=""
current_alpha=""
current_status=""

flush_check() {
    [[ -z "$current_name" ]] && return

    local should_reap=false
    local reason=""

    # Check status
    if echo "$current_status" | grep -qiE 'Halted|Disconnected|error'; then
        should_reap=true
        reason="status: $current_status"
    fi

    # Check local alpha path exists
    if [[ -n "$current_alpha" ]] && ! test -d "$current_alpha"; then
        should_reap=true
        reason="${reason:+$reason; }alpha path gone: $current_alpha"
    fi

    if [[ "$should_reap" == "true" ]]; then
        echo "sync-reap: terminating '$current_name' ($reason)"
        mutagen sync terminate "$current_name" 2>/dev/null && reaped=$((reaped + 1)) || true
    fi
}

while IFS= read -r line; do
    case "$line" in
        Name:*)
            flush_check
            current_name="${line#Name: }"
            current_name="${current_name#"${current_name%%[![:space:]]*}"}"  # ltrim
            current_alpha=""
            current_status=""
            ;;
        *"URL:"*)
            # Alpha URL line (local path). Appears inside the Alpha: block.
            # Only capture the first URL (alpha); beta URL follows later.
            if [[ -z "$current_alpha" ]]; then
                current_alpha="${line#*URL: }"
                current_alpha="${current_alpha#"${current_alpha%%[![:space:]]*}"}"
            fi
            ;;
        Status:*)
            current_status="${line#Status: }"
            current_status="${current_status#"${current_status%%[![:space:]]*}"}"
            ;;
    esac
done <<< "$session_list"

# Final block
flush_check

echo "sync-reap: done (reaped $reaped session(s))"

# Second pass: reap stale per-session mode files
"$SCRIPT_DIR/session-reap.sh"

exit 0
