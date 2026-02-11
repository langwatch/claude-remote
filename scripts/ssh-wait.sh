#!/usr/bin/env bash
#
# SSH with wait-for-host retry loop
# Polls until the remote is reachable, then connects (with optional tmux)
#
# Usage:
#   ssh-wait              # wait + connect with tmux
#   ssh-wait --no-tmux    # wait + plain SSH
#   ssh-wait main         # wait + tmux session named "main"
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

USE_TMUX=true
SESSION_NAME="main"

for arg in "$@"; do
    case "$arg" in
        --no-tmux) USE_TMUX=false ;;
        *) SESSION_NAME="$arg" ;;
    esac
done

INTERVAL=10

# Check if already reachable
if ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null; then
    echo "Remote is up."
else
    echo "Remote ($REMOTE_HOST) is down. Waiting..."
    while true; do
        sleep "$INTERVAL"
        if ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null; then
            echo ""
            echo "Remote is back! Connecting..."
            osascript -e 'display notification "Remote instance is back!" with title "Claude Remote"' 2>/dev/null
            break
        fi
        printf "."
    done
fi

if $USE_TMUX; then
    exec ssh -t "$REMOTE_HOST" "cd $REMOTE_DIR && tmux new-session -A -s $SESSION_NAME"
else
    exec ssh -t "$REMOTE_HOST" "cd $REMOTE_DIR && /bin/bash -l"
fi
