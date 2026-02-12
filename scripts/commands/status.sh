#
# claude-remote status — diagnostic status check
# Sourced by claude-remote.sh dispatcher (SCRIPT_DIR and config already loaded)
#

cmd_status() {
    local REPO_DIR
    REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

    echo "Claude Remote Status"
    echo "===================="
    echo

    # --- Config ---
    echo "Config:"
    echo "  REMOTE_HOST:     ${REMOTE_HOST:-<not set>}"
    echo "  REMOTE_DIR:      ${REMOTE_DIR:-<not set>}"
    echo "  LOCAL_MOUNT:     ${LOCAL_MOUNT:-<not set>}"
    echo "  DEFAULT_PROJECT: ${DEFAULT_PROJECT:-<not set>}"
    echo

    # --- Symlink health ---
    echo "Symlinks:"
    local ZSH_LINK="$SCRIPT_DIR/zsh"
    if [[ -L "$ZSH_LINK" ]]; then
        local target
        target="$(readlink "$ZSH_LINK")"
        if [[ -e "$ZSH_LINK" ]]; then
            echo "  OK: scripts/zsh -> $target"
        else
            echo "  BROKEN: scripts/zsh -> $target (target does not exist)"
        fi
    else
        echo "  MISSING: scripts/zsh symlink does not exist"
    fi

    local BIN_LINK="$HOME/bin/claude-remote"
    if [[ -L "$BIN_LINK" ]]; then
        local target
        target="$(readlink "$BIN_LINK")"
        if [[ -e "$BIN_LINK" ]]; then
            if [[ "$target" == "$REPO_DIR/scripts/"* ]]; then
                echo "  OK: ~/bin/claude-remote -> $target"
            else
                echo "  WARN: ~/bin/claude-remote -> $target (points elsewhere)"
            fi
        else
            echo "  BROKEN: ~/bin/claude-remote -> $target"
        fi
    else
        echo "  MISSING: ~/bin/claude-remote"
    fi
    echo

    # --- SSH connectivity ---
    echo "SSH:"
    if [[ -z "$REMOTE_HOST" ]]; then
        echo "  SKIP: REMOTE_HOST not configured"
    else
        local SOCKET="/tmp/ssh-claude-${REMOTE_HOST}:22"
        if [[ -S "$SOCKET" ]]; then
            echo "  Control socket: $SOCKET (exists)"
        else
            echo "  Control socket: none"
        fi

        if ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "echo ok" 2>/dev/null | grep -q ok; then
            echo "  Connection: OK"
            local remote_info
            remote_info=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "hostname && uname -s" 2>/dev/null)
            echo "  Remote: $remote_info"
        else
            echo "  Connection: FAILED"
        fi
    fi
    echo

    # --- Mutagen sync ---
    echo "Mutagen sync:"
    if ! command -v mutagen &>/dev/null; then
        echo "  SKIP: mutagen not installed"
    else
        local sessions
        sessions=$(mutagen sync list --label-selector=name=claude-remote 2>/dev/null)
        if [[ -z "$sessions" ]]; then
            echo "  No active sync sessions"
        else
            echo "$sessions" | sed 's/^/  /'
        fi
    fi
}
