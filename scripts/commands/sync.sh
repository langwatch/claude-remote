#
# claude-remote sync — manage Mutagen file sync
# Sourced by claude-remote.sh dispatcher (SCRIPT_DIR and config already loaded)
#

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

_create_sync_session() {
    local name="$1"
    local local_path="$2"
    local remote_path="$3"

    if mutagen sync list 2>/dev/null | grep -q "Name: $name"; then
        echo "Sync '$name' already running"
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
        echo "Sync '$name' created"
    else
        echo "Failed to create sync '$name'" >&2
        return 1
    fi
}

_sync_start() {
    mutagen daemon start 2>/dev/null

    if [[ -n "${1:-}" ]]; then
        local TARGET
        TARGET="$(cd "$1" 2>/dev/null && pwd -P)"

        if [[ "$TARGET" != "$LOCAL_MOUNT"* ]]; then
            echo "Error: $TARGET is not under $LOCAL_MOUNT" >&2
            return 1
        fi

        local REL="${TARGET#$LOCAL_MOUNT/}"
        local PROJECT="${REL%%/*}"

        if [[ -z "$PROJECT" ]]; then
            echo "Error: could not determine project from $TARGET" >&2
            return 1
        fi

        _create_sync_session "claude-remote-$PROJECT" "$LOCAL_MOUNT/$PROJECT" "$REMOTE_DIR/$PROJECT"
    else
        if [[ ${#SYNC_INCLUDE[@]} -gt 0 ]] 2>/dev/null; then
            for dir in "${SYNC_INCLUDE[@]}"; do
                _create_sync_session "claude-remote-$dir" "$LOCAL_MOUNT/$dir" "$REMOTE_DIR/$dir"
            done
        else
            mkdir -p "$LOCAL_MOUNT"
            _create_sync_session "claude-remote" "$LOCAL_MOUNT" "$REMOTE_DIR"
        fi
    fi

    echo "Waiting for sync... Ctrl-C to cancel"
    local attempts=0
    local max_attempts=60  # 5 minutes at 5s intervals
    while ! mutagen sync flush --label-selector=name=claude-remote 2>/dev/null; do
        ((attempts++))
        if [[ $attempts -ge $max_attempts ]]; then
            echo "Sync timed out after ${max_attempts} attempts" >&2
            return 1
        fi
        printf "."
        sleep 5
    done
    echo ""
    echo "Sync ready"

    # Heal git worktree paths on both sides
    if type cmd_heal &>/dev/null; then
        cmd_heal both 2>/dev/null
    fi
}

_sync_stop() {
    if mutagen sync list 2>/dev/null | grep -q "claude-remote"; then
        echo "Stopping sync..."
        mutagen sync terminate --label-selector=name=claude-remote
        echo "Sync stopped"
    else
        echo "No sync sessions running"
    fi
}

_sync_status() {
    mutagen sync list --label-selector=name=claude-remote 2>/dev/null || echo "No sync sessions running"
}

cmd_sync() {
    case "${1:-}" in
        stop)   shift; _sync_stop "$@" ;;
        status) shift; _sync_status "$@" ;;
        *)      _sync_start "$@" ;;
    esac
}
