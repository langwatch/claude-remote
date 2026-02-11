#!/usr/bin/env bash
#
# Diagnostic status for claude-remote
# Reports: config, SSH connectivity, Mutagen sync, symlinks, control socket
#

# Resolve symlinks to find the real script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Claude Remote Status"
echo "===================="
echo

# --- Config ---
echo "Config:"
if [[ -f "$SCRIPT_DIR/../config.sh" ]]; then
    source "$SCRIPT_DIR/../config.sh"
    echo "  REMOTE_HOST:     ${REMOTE_HOST:-<not set>}"
    echo "  REMOTE_DIR:      ${REMOTE_DIR:-<not set>}"
    echo "  LOCAL_MOUNT:     ${LOCAL_MOUNT:-<not set>}"
    echo "  DEFAULT_PROJECT: ${DEFAULT_PROJECT:-<not set>}"
else
    echo "  ERROR: config.sh not found. Run ./setup.sh first."
fi
echo

# --- Symlink health ---
echo "Symlinks (scripts/zsh):"
ZSH_LINK="$SCRIPT_DIR/zsh"
if [[ -L "$ZSH_LINK" ]]; then
    TARGET="$(readlink "$ZSH_LINK")"
    if [[ -e "$ZSH_LINK" ]]; then
        echo "  OK: zsh -> $TARGET"
    else
        echo "  BROKEN: zsh -> $TARGET (target does not exist)"
    fi
else
    echo "  MISSING: scripts/zsh symlink does not exist"
fi
echo

# --- ~/bin symlinks ---
echo "~/bin symlinks:"
BIN_DIR="$HOME/bin"
for cmd in claude-remote mount-remote unmount-remote sync-start sync-status sync-stop ssh-tmux ssh-wait remote-status; do
    link="$BIN_DIR/$cmd"
    if [[ -L "$link" ]]; then
        target="$(readlink "$link")"
        if [[ -e "$link" ]]; then
            # Check if it points to this repo
            if [[ "$target" == "$REPO_DIR/scripts/"* ]]; then
                echo "  OK: $cmd -> $target"
            else
                echo "  WARN: $cmd -> $target (points elsewhere)"
            fi
        else
            echo "  BROKEN: $cmd -> $target"
        fi
    else
        echo "  MISSING: $cmd"
    fi
done
echo

# --- SSH connectivity ---
echo "SSH:"
if [[ -z "$REMOTE_HOST" ]]; then
    echo "  SKIP: REMOTE_HOST not configured"
else
    SOCKET="/tmp/ssh-claude-${REMOTE_HOST}:22"
    if [[ -S "$SOCKET" ]]; then
        echo "  Control socket: $SOCKET (exists)"
    else
        echo "  Control socket: none"
    fi

    if ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "echo ok" 2>/dev/null | grep -q ok; then
        echo "  Connection: OK"
        REMOTE_UNAME=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "hostname && uname -s" 2>/dev/null)
        echo "  Remote: $REMOTE_UNAME"
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
    SESSIONS=$(mutagen sync list --label-selector=name=claude-remote 2>/dev/null)
    if [[ -z "$SESSIONS" ]]; then
        echo "  No active claude-remote sync sessions"
    else
        echo "$SESSIONS" | sed 's/^/  /'
    fi
fi
