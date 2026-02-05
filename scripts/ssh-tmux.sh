#!/usr/bin/env bash
#
# SSH with transparent tmux session persistence
# Usage: ssh-tmux [session-name]
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

SESSION_NAME="${1:-main}"

exec ssh -t "$REMOTE_HOST" "cd $REMOTE_DIR && tmux new-session -A -s $SESSION_NAME"

