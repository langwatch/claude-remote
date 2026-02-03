#!/usr/bin/env bash
#
# Launch Claude Code with remote execution and filesystem
# Usage: claude-remote [path]
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

# Ensure mutagen sync is running
"$SCRIPT_DIR/sync-start.sh"

# Default path or use first argument
if [[ -n "$1" && -d "$1" ]]; then
    WORK_PATH="$1"
    shift
else
    WORK_PATH="${DEFAULT_PROJECT:-$LOCAL_MOUNT}"
fi

# Launch Claude with remote shell
cd "$WORK_PATH"
SHELL="$SCRIPT_DIR/zsh" exec claude --dangerously-skip-permissions "$@"
