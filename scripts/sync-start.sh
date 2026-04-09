#!/usr/bin/env bash
#
# Start Mutagen sync session for the current working directory
# Usage: sync-start [path]
#   Syncs the given path (or CWD) to REMOTE_MIRROR_ROOT/<absolute-path>
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

# Ensure daemon is running
mutagen daemon start 2>/dev/null

# Common ignore flags
IGNORE_FLAGS=(
    --ignore="node_modules"
    --ignore=".venv"
    --ignore=".cache"
    --ignore="dist"
    --ignore=".next*"
    --ignore="__pycache__"
    --ignore=".pytest_cache"
    --ignore=".mypy_cache"
    --ignore=".turbo"
    --ignore="*.pyc"
    --ignore=".DS_Store"
    --ignore="coverage"
    --ignore=".nyc_output"
    --ignore="target"
    --ignore="build"
)

create_sync_session() {
    local name="$1"
    local local_path="$2"
    local remote_path="$3"

    # Check if this specific session already exists
    if mutagen sync list 2>/dev/null | grep -q "Name: $name"; then
        echo "✓ Sync '$name' already running"
        return 0
    fi

    echo "Creating sync: $name ($local_path -> $remote_path)..."
    ssh -o ConnectTimeout=5 "$REMOTE_HOST" "mkdir -p '$remote_path'" 2>/dev/null
    mutagen sync create "$local_path" "$REMOTE_HOST:$remote_path" \
        --name="$name" \
        --label=name=claude-remote \
        "${IGNORE_FLAGS[@]}" \
        --sync-mode=two-way-resolved \
        --default-file-mode=0644 \
        --default-directory-mode=0755

    if [ $? -eq 0 ]; then
        echo "✓ $name created"
    else
        echo "✗ Failed to create $name"
        return 1
    fi
}

# Resolve the target directory
if [[ -n "$1" ]]; then
    TARGET="$(cd "$1" 2>/dev/null && pwd -P)"
else
    TARGET="$(pwd -P)"
fi

if [[ -z "$TARGET" || ! -d "$TARGET" ]]; then
    echo "Error: could not resolve directory: ${1:-$(pwd)}"
    exit 1
fi

# Session name: sanitize absolute path into a valid mutagen name
SESSION_NAME="claude-remote-$(echo "$TARGET" | tr '/' '-' | sed 's/^-//')"

# Remote path: mirror the full local absolute path under REMOTE_MIRROR_ROOT
REMOTE_PATH="${REMOTE_MIRROR_ROOT}${TARGET}"

create_sync_session "$SESSION_NAME" "$TARGET" "$REMOTE_PATH"

echo "Waiting for sync..."
mutagen sync flush --label-selector=name=claude-remote
echo "✓ Sync ready"
