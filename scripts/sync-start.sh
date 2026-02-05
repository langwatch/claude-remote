#!/usr/bin/env bash
#
# Start Mutagen sync session
# Usage: sync-start [path]
#   If path is given, syncs just that project directory
#   If no path, syncs all SYNC_INCLUDE dirs (or entire LOCAL_MOUNT)
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

# If a path was passed, resolve it to a project name relative to LOCAL_MOUNT
if [[ -n "$1" ]]; then
    TARGET="$(cd "$1" 2>/dev/null && pwd -P)"

    # Ensure it's under LOCAL_MOUNT
    if [[ "$TARGET" != "$LOCAL_MOUNT"* ]]; then
        echo "Error: $TARGET is not under $LOCAL_MOUNT"
        exit 1
    fi

    # Get the first path component relative to LOCAL_MOUNT (the project dir)
    REL="${TARGET#$LOCAL_MOUNT/}"
    PROJECT="${REL%%/*}"

    if [[ -z "$PROJECT" ]]; then
        echo "Error: could not determine project from $TARGET"
        exit 1
    fi

    create_sync_session "claude-remote-$PROJECT" "$LOCAL_MOUNT/$PROJECT" "$REMOTE_DIR/$PROJECT"
else
    # No path given — sync SYNC_INCLUDE list or everything
    if [[ ${#SYNC_INCLUDE[@]} -gt 0 ]]; then
        for dir in "${SYNC_INCLUDE[@]}"; do
            create_sync_session "claude-remote-$dir" "$LOCAL_MOUNT/$dir" "$REMOTE_DIR/$dir"
        done
    else
        mkdir -p "$LOCAL_MOUNT"
        create_sync_session "claude-remote" "$LOCAL_MOUNT" "$REMOTE_DIR"
    fi
fi

echo "Waiting for sync..."
mutagen sync flush --label-selector=name=claude-remote
echo "✓ Sync ready"
