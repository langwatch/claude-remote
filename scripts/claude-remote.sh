#!/usr/bin/env bash
#
# claude-remote — run Claude Code with remote execution
#
# Usage:
#   claude-remote [path] [flags]   Launch Claude (default)
#   claude-remote status            Diagnostic status
#   claude-remote sync [path]       Start/ensure Mutagen sync
#   claude-remote sync stop         Stop sync
#   claude-remote sync status       Show sync state
#   claude-remote shell             Interactive tmux session picker
#   claude-remote shell [name]      Attach/create named tmux session
#   claude-remote help              Show this help
#

# Resolve symlinks to find the real script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# Source config (not required for help)
if [[ "${1:-}" != "help" && "${1:-}" != "-h" && "${1:-}" != "--help" ]]; then
    source "$SCRIPT_DIR/../config.sh" 2>/dev/null || {
        echo "Error: config.sh not found. Run ./setup.sh first." >&2
        exit 1
    }
fi

# Source command implementations
CMD_DIR="$SCRIPT_DIR/commands"
source "$CMD_DIR/launch.sh"
source "$CMD_DIR/status.sh"
source "$CMD_DIR/sync.sh"
source "$CMD_DIR/shell.sh"
source "$CMD_DIR/heal.sh"

_show_help() {
    echo "claude-remote — run Claude Code on a remote machine"
    echo ""
    echo "Usage:"
    echo "  claude-remote [path] [flags]   Launch Claude (default)"
    echo "  claude-remote status            Diagnostic status check"
    echo "  claude-remote sync [path]       Start/ensure Mutagen sync"
    echo "  claude-remote sync stop         Stop all sync sessions"
    echo "  claude-remote sync status       Show sync state"
    echo "  claude-remote shell             Interactive tmux session picker"
    echo "  claude-remote shell [name]      Attach/create named tmux session"
    echo "  claude-remote heal [local|remote|both]  Fix git worktree paths"
    echo "  claude-remote help              Show this help"
}

# Route subcommand
case "${1:-}" in
    status)          shift; cmd_status "$@" ;;
    sync)            shift; cmd_sync "$@" ;;
    shell)           shift; cmd_shell "$@" ;;
    heal)            shift; cmd_heal "$@" ;;
    help|-h|--help)  _show_help ;;
    *)               cmd_launch "$@" ;;
esac
