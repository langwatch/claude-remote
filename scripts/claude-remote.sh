#!/usr/bin/env bash
#
# Launch Claude Code with remote execution and filesystem
# Usage: claude-remote [claude-args...]
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

# Always use CWD
WORK_PATH="$(pwd -P)"

# Ensure mutagen sync is running for this directory
"$SCRIPT_DIR/sync-start.sh" "$WORK_PATH"

# Check remote shell connection
echo "Remote shell connection:"
"$SCRIPT_DIR/remote-shell.sh" -c "uname -a"

# Launch Claude with remote shell
SHELL="$SCRIPT_DIR/zsh" exec claude --dangerously-skip-permissions "$@"
