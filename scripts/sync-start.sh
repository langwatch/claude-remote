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
source "$SCRIPT_DIR/lib-mode.sh" || {
    echo "Error: lib-mode.sh not found." >&2
    exit 1
}

if [[ -z "$REMOTE_MIRROR_ROOT" ]]; then
    echo "Error: REMOTE_MIRROR_ROOT not set in config.sh" >&2
    exit 1
fi

# PATH_IDENTITY mode: sync to the identical absolute path on the remote box.
# When false (legacy), mirror under REMOTE_MIRROR_ROOT.
# The box-side parent directory (/Users/<user>) must exist and be writable by
# the ssh user — setup.sh handles this when PATH_IDENTITY is enabled.

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
    if [[ "${PATH_IDENTITY:-false}" == "true" ]]; then
        # PATH_IDENTITY: remote path is under /Users/... (not user-writable without sudo).
        # Create the dir via sudo and chown it to the ssh user so mutagen can write.
        # \$(id -un) and \$(id -gn) are intentionally escaped so they evaluate on the remote box.
        ssh -o ConnectTimeout=5 "$REMOTE_HOST" "sudo mkdir -p '$remote_path' && sudo chown \$(id -un):\$(id -gn) '$remote_path'"
    else
        ssh -o ConnectTimeout=5 "$REMOTE_HOST" "mkdir -p '$remote_path'" 2>/dev/null
    fi

    # Fail loud: verify the remote path exists before starting a sync session that would
    # silently succeed but sync nothing.
    if ! ssh -o ConnectTimeout=5 "$REMOTE_HOST" "test -d '$remote_path'"; then
        echo "✗ remote path '$remote_path' could not be created on $REMOTE_HOST" >&2
        echo "  (PATH_IDENTITY mode needs the identity root to exist + be writable; re-run setup.sh or:" >&2
        echo "   ssh $REMOTE_HOST 'sudo mkdir -p $remote_path && sudo chown <user> $remote_path')" >&2
        return 1
    fi

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

# Session name: sanitize absolute path into a valid mutagen name (alphanumeric + hyphens only)
SESSION_NAME="$(_session_name_for "$TARGET")"

# === FIX 1: PATH IDENTITY ===
# Remote path: when PATH_IDENTITY=true use the identical absolute path on the box;
# when false (legacy) mirror under REMOTE_MIRROR_ROOT.
if [[ "${PATH_IDENTITY:-false}" == "true" ]]; then
    REMOTE_PATH="${TARGET}"
else
    REMOTE_PATH="${REMOTE_MIRROR_ROOT}${TARGET}"
fi

create_sync_session "$SESSION_NAME" "$TARGET" "$REMOTE_PATH"

echo "Waiting for sync..."
mutagen sync flush --label-selector=name=claude-remote
echo "✓ Sync ready"
