#!/usr/bin/env bash
#
# Paste Mac clipboard image to remote machine and copy path
# Usage: paste-image-remote [session-name]
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

SESSION_NAME="${1:-}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOCAL_TMP="/tmp/clipboard_${TIMESTAMP}.png"
REMOTE_CACHE="${REMOTE_IMAGE_CACHE:-/home/ubuntu/.cache/tmux-paste-image}"
REMOTE_PATH="${REMOTE_CACHE}/clipboard_${TIMESTAMP}.png"

# Get image from Mac clipboard using pngpaste (or osascript fallback)
if command -v pngpaste &> /dev/null; then
    pngpaste "$LOCAL_TMP"
else
    osascript -e 'tell application "System Events" to ¬
        write (the clipboard as «class PNGf») to ¬
        (make new file at folder "'"$(dirname "$LOCAL_TMP")"'" with properties {name:"'"$(basename "$LOCAL_TMP")"'"})' 2>/dev/null
fi

if [[ ! -f "$LOCAL_TMP" ]]; then
    echo "No image in clipboard"
    exit 1
fi

# Ensure remote dir exists and copy
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_CACHE"
scp -q "$LOCAL_TMP" "$REMOTE_HOST:$REMOTE_PATH"
rm "$LOCAL_TMP"

# If session specified, send the path to that tmux session
if [[ -n "$SESSION_NAME" ]]; then
    ssh "$REMOTE_HOST" "tmux send-keys -t $SESSION_NAME '$REMOTE_PATH' Enter"
    echo "Sent to tmux session: $SESSION_NAME"
else
    # Just copy path to Mac clipboard
    echo -n "$REMOTE_PATH" | pbcopy
    echo "Image uploaded: $REMOTE_PATH (path copied to clipboard)"
fi
