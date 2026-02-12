#
# claude-remote heal — fix git worktree paths after sync
# Sourced by claude-remote.sh dispatcher (SCRIPT_DIR and config already loaded)
#
# Git worktrees store absolute paths in two places:
#   1. <worktree>/.git         — "gitdir: /abs/path/to/.git/worktrees/<name>"
#   2. .git/worktrees/<name>/gitdir — "/abs/path/to/<worktree>/.git"
# When synced between machines with different home dirs, these paths break.
#

_heal_local() {
    local wrong="$REMOTE_DIR"
    local right="$LOCAL_MOUNT"
    local fixed=0

    # Step 1: Fix .git files in worktree checkouts
    for f in $(find "$LOCAL_MOUNT" -maxdepth 3 -name .git -not -type d 2>/dev/null); do
        if grep -q "$wrong" "$f" 2>/dev/null; then
            sed -i '' "s|$wrong|$right|g" "$f"
            ((fixed++))
        fi
        # Step 2: Follow the gitdir pointer to fix the reverse link
        local gitdir
        gitdir=$(sed 's/^gitdir: //' "$f" 2>/dev/null)
        if [[ -f "$gitdir/gitdir" ]] && grep -q "$wrong" "$gitdir/gitdir" 2>/dev/null; then
            sed -i '' "s|$wrong|$right|g" "$gitdir/gitdir"
            ((fixed++))
        fi
    done

    echo "Healed $fixed path(s) locally"
}

_heal_remote() {
    local wrong="$LOCAL_MOUNT"
    local right="$REMOTE_DIR"

    ssh -o ConnectTimeout=5 "$REMOTE_HOST" bash -s -- "$right" "$wrong" <<'SCRIPT'
right="$1"
wrong="$2"
fixed=0

for f in $(find "$right" -maxdepth 3 -name .git -not -type d 2>/dev/null); do
    if grep -q "$wrong" "$f" 2>/dev/null; then
        sed -i "s|$wrong|$right|g" "$f"
        ((fixed++))
    fi
    gitdir=$(sed 's/^gitdir: //' "$f" 2>/dev/null)
    if [[ -f "$gitdir/gitdir" ]] && grep -q "$wrong" "$gitdir/gitdir" 2>/dev/null; then
        sed -i "s|$wrong|$right|g" "$gitdir/gitdir"
        ((fixed++))
    fi
done

echo "Healed $fixed path(s) on remote"
SCRIPT
}

cmd_heal() {
    case "${1:-both}" in
        local)  _heal_local ;;
        remote) _heal_remote ;;
        both)   _heal_local; _heal_remote ;;
        *)      echo "Usage: claude-remote heal [local|remote|both]" >&2; return 1 ;;
    esac
}
