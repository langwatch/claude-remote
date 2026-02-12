#
# claude-remote shell — SSH + tmux session management
# Sourced by claude-remote.sh dispatcher (SCRIPT_DIR and config already loaded)
#

_wait_for_remote() {
    if ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null; then
        return 0
    fi

    echo "Waiting for remote ($REMOTE_HOST)... Ctrl-C to cancel"
    while true; do
        sleep 5
        if ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null; then
            echo ""
            echo "Remote is up!"
            osascript -e 'display notification "Remote instance is back!" with title "Claude Remote"' 2>/dev/null
            return 0
        fi
        printf "."
    done
}

_session_picker() {
    while true; do
        local sessions
        sessions=$(ssh -o ConnectTimeout=3 "$REMOTE_HOST" \
            "tmux list-sessions -F '#{session_name}|#{session_windows}|#{?session_attached,attached,detached}'" 2>/dev/null)

        if [[ -z "$sessions" ]]; then
            echo "No tmux sessions on remote."
            local name
            read -p "Create session [main]: " name
            name="${name:-main}"
            exec ssh -t "$REMOTE_HOST" "cd $REMOTE_DIR && tmux new-session -s $name"
        fi

        echo ""
        echo "Remote tmux sessions:"
        local i=1
        local names=()
        while IFS='|' read -r sname windows attached; do
            names+=("$sname")
            local suffix=""
            [[ "$windows" -ne 1 ]] && suffix="s"
            printf "  %d) %-20s (%s window%s, %s)\n" "$i" "$sname" "$windows" "$suffix" "$attached"
            ((i++))
        done <<< "$sessions"

        echo ""
        read -p "  [j]oin #  [k]ill #  [n]ew  [q]uit > " action

        case "$action" in
            j[0-9]*)
                local idx="${action#j}"
                if [[ $idx -ge 1 && $idx -le ${#names[@]} ]]; then
                    local target="${names[$((idx-1))]}"
                    exec ssh -t "$REMOTE_HOST" "cd $REMOTE_DIR && tmux attach -t $target"
                else
                    echo "Invalid session number"
                fi
                ;;
            k[0-9]*)
                local idx="${action#k}"
                if [[ $idx -ge 1 && $idx -le ${#names[@]} ]]; then
                    local target="${names[$((idx-1))]}"
                    ssh "$REMOTE_HOST" "tmux kill-session -t $target"
                    echo "Killed: $target"
                else
                    echo "Invalid session number"
                fi
                ;;
            n)
                local name
                read -p "Session name [main]: " name
                name="${name:-main}"
                exec ssh -t "$REMOTE_HOST" "cd $REMOTE_DIR && tmux new-session -s $name"
                ;;
            q)
                exit 0
                ;;
            *)
                echo "Unknown action: $action"
                ;;
        esac
    done
}

cmd_shell() {
    [[ -t 0 ]] || { echo "Error: shell requires a terminal" >&2; exit 1; }

    _wait_for_remote

    if [[ -n "${1:-}" ]]; then
        exec ssh -t "$REMOTE_HOST" "cd $REMOTE_DIR && tmux new-session -A -s $1"
    else
        _session_picker
    fi
}
