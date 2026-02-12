#!/usr/bin/env bash
#
# Remote shell wrapper for Claude Code
# Intercepts shell commands and executes them on the remote machine
# Falls back to local execution if remote is unavailable
#

# Resolve symlinks to find the real script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
source "$SCRIPT_DIR/../config.sh" 2>/dev/null || {
    echo "Error: config.sh not found. Run ./setup.sh first." >&2
    exit 1
}

SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-claude-%r@%h:%p -o ControlPersist=600 -o ConnectTimeout=5"
STATE_FILE="/tmp/claude-remote-state"
NOTIFY_COOLDOWN=300  # 5 minutes

# Map local path to remote path
local_to_remote() {
    echo "${1/#$LOCAL_MOUNT/$REMOTE_DIR}"
}

# Map remote path to local path
remote_to_local() {
    echo "${1/#$REMOTE_DIR/$LOCAL_MOUNT}"
}

# Send macOS notification with rate limiting
notify() {
    local message="$1"
    local state="$2"  # "offline" or "online"
    local now=$(date +%s)
    local last_state=""
    local last_notify=0

    if [[ -f "$STATE_FILE" ]]; then
        last_state=$(head -1 "$STATE_FILE")
        last_notify=$(tail -1 "$STATE_FILE")
    fi

    # Only notify if state changed, or still offline after cooldown
    if [[ "$state" != "$last_state" ]] || { [[ "$state" == "offline" ]] && [[ $((now - last_notify)) -ge $NOTIFY_COOLDOWN ]]; }; then
        osascript -e "display notification \"$message\" with title \"Claude Remote\"" 2>/dev/null
        echo -e "$state\n$now" > "$STATE_FILE"
    fi
}

# Check if remote is reachable (fast check via SSH ConnectTimeout)
is_remote_available() {
    # First check if control socket exists but is stale
    local socket="/tmp/ssh-claude-${REMOTE_HOST}:22"
    if [[ -S "$socket" ]]; then
        # Test if socket is alive, remove if stale
        if ! /usr/bin/ssh -o ControlPath="$socket" -o ConnectTimeout=1 -O check "$REMOTE_HOST" 2>/dev/null; then
            /bin/rm -f "$socket" 2>/dev/null
        fi
    fi
    /usr/bin/ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null
}

# Parse flags - Claude Code sends: -c -l "command"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) shift ;;
        -l|-i) shift ;;
        *) cmd="$1"; break ;;
    esac
done

if [[ -n "$cmd" ]]; then
    # Extract pwd file if present
    pwd_file=""
    if [[ "$cmd" =~ (.*)(\&\&\ pwd\ -P\ \>\|\ ([^[:space:]]+))$ ]]; then
        cmd="${BASH_REMATCH[1]}"
        pwd_file="${BASH_REMATCH[3]}"
    fi

    LOCAL_CWD="$(pwd -P)"

    # Check remote availability
    if is_remote_available; then
        # === REMOTE EXECUTION ===
        notify "Remote instance available" "online"

        REMOTE_CWD="$(local_to_remote "$LOCAL_CWD")"

        # Map local paths in command to remote
        cmd="${cmd//$LOCAL_MOUNT/$REMOTE_DIR}"

        # Flush mutagen sync before command
        mutagen sync flush --label-selector=name=claude-remote >/dev/null 2>&1

        # Build remote command
        # Source .profile and .bashrc (with non-interactive guard disabled)
        MARKER="__CLAUDE_REMOTE_PWD__"
        # Heal worktree .git file on remote if needed (sync may have overwritten with local paths)
        HEAL_CMD="[[ -f '$REMOTE_CWD/.git' ]] && grep -q '$LOCAL_MOUNT' '$REMOTE_CWD/.git' 2>/dev/null && sed -i 's|$LOCAL_MOUNT|$REMOTE_DIR|g' '$REMOTE_CWD/.git';"
        remote_cmd="source ~/.profile 2>/dev/null; source <(sed 's/return;;/;;/' ~/.bashrc) 2>/dev/null; $HEAL_CMD cd '$REMOTE_CWD' 2>/dev/null || cd '$REMOTE_DIR'; /bin/bash -c $(printf '%q' "$cmd"); echo $MARKER; pwd -P"

        # Run and capture output
        remote_output=$(/usr/bin/ssh $SSH_OPTS "$REMOTE_HOST" "$remote_cmd")
        exit_code=$?

        # Flush mutagen sync after command
        mutagen sync flush --label-selector=name=claude-remote >/dev/null 2>&1

        # Heal git worktree paths in cwd (sync may have overwritten .git file)
        if [[ -f "$LOCAL_CWD/.git" ]] && grep -q "$REMOTE_DIR" "$LOCAL_CWD/.git" 2>/dev/null; then
            sed -i '' "s|$REMOTE_DIR|$LOCAL_MOUNT|g" "$LOCAL_CWD/.git"
        fi

        # Split output and handle pwd
        if [[ "$remote_output" == *"$MARKER"* ]]; then
            cmd_output="${remote_output%$MARKER*}"
            remote_pwd="${remote_output##*$MARKER}"
            remote_pwd=$(echo "$remote_pwd" | tr -d '\n')
            printf "%s" "$cmd_output"
            if [[ -n "$pwd_file" ]]; then
                echo "$(remote_to_local "$remote_pwd")" > "$pwd_file"
            fi
        else
            echo "$remote_output"
            [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
        fi
    else
        # === LOCAL FALLBACK ===
        notify "Remote unavailable - using local execution" "offline"

        # Map remote paths in command to local (in case command has hardcoded remote paths)
        cmd="${cmd//$REMOTE_DIR/$LOCAL_MOUNT}"
        # Also map local paths that might have been transformed
        cmd="${cmd//$LOCAL_MOUNT/$LOCAL_MOUNT}"  # no-op but keeps consistency

        # Run locally
        MARKER="__CLAUDE_LOCAL_PWD__"
        local_output=$(/bin/bash -c "$cmd; echo $MARKER; pwd -P" 2>&1)
        exit_code=$?

        # Split output and handle pwd
        if [[ "$local_output" == *"$MARKER"* ]]; then
            cmd_output="${local_output%$MARKER*}"
            local_pwd="${local_output##*$MARKER}"
            local_pwd=$(echo "$local_pwd" | tr -d '\n')
            printf "%s" "$cmd_output"
            [[ -n "$pwd_file" ]] && echo "$local_pwd" > "$pwd_file"
        else
            echo "$local_output"
            [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
        fi
    fi

    exit $exit_code
else
    # Interactive shell
    if is_remote_available; then
        notify "Remote instance available" "online"
        REMOTE_CWD="$(local_to_remote "$(pwd -P)")"
        /usr/bin/ssh $SSH_OPTS -t "$REMOTE_HOST" "cd '$REMOTE_CWD' 2>/dev/null || cd '$REMOTE_DIR'; /bin/bash -l"
    else
        notify "Remote unavailable - using local shell" "offline"
        /bin/bash -l
    fi
fi
