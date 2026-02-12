#
# claude-remote launch — start Claude Code with remote execution
# Sourced by claude-remote.sh dispatcher (SCRIPT_DIR and config already loaded)
#

cmd_launch() {
    if [[ -n "${1:-}" && -d "$1" ]]; then
        WORK_PATH="$1"
        shift
    else
        WORK_PATH="${DEFAULT_PROJECT:-$(pwd)}"
    fi

    # Ensure mutagen sync is running for this project
    _sync_start "$WORK_PATH"

    # Launch Claude with remote shell
    cd "$WORK_PATH"
    SHELL="$SCRIPT_DIR/zsh" exec claude --dangerously-skip-permissions "$@"
}
