#!/usr/bin/env bash
#
# lib-mode.sh — shared mode/url resolution for claude-remote
#
# Source this file; do NOT execute it directly.
# Callers must set STATE_DIR before sourcing (or rely on the default).
#
# Public functions:
#   _validate_session_id  <id>   → exits 0 if well-formed UUID, 1 otherwise
#   _resolve_mode                → prints resolved raw value (trimmed)
#   _resolve_mode_source         → prints winning layer name (session|project|global|seed|default)
#   _resolve_url                 → prints effective host
#
# Precedence (highest first):
#   1. session file   ${STATE_DIR}/session/${CLAUDE_CODE_SESSION_ID}
#      — only consulted when CLAUDE_CODE_SESSION_ID is a well-formed UUID
#      — malformed (non-empty, non-UUID) id → WARNING to stderr, skip layer
#      — unset/empty id → skip silently
#      — file format: line 1 = mode (on|off); optional line 2 = "pid:<owner>"
#        (a liveness token consumed by session-reap.sh; only line 1 is the mode)
#   2. project-local  ${CLAUDE_PROJECT_DIR}/.claude-remote-mode
#      — only consulted when CLAUDE_PROJECT_DIR is set AND file exists
#   3. global file    ${STATE_DIR}/mode
#   4. env seed       $CLAUDE_REMOTE_MODE  (launch-time only)
#   5. default        on
#
# Trim: all whitespace (space, tab, CR, newline) via [![:space:]]
#

# UUID validator: exactly 8-4-4-4-12 hex chars separated by hyphens
_validate_session_id() {
    local id="${1:-}"
    [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# _session_owner_pid: print the PID of the durable session-owner process.
#
# WHY this exists (the live-state-deletion bug, PR #7):
#   The per-session mode file is keyed by $CLAUDE_CODE_SESSION_ID, which the
#   writer reads from its environment. The reaper, however, cannot observe that
#   UUID at reap time: on macOS it is in NEITHER the session-launcher's argv
#   ("claude --agent lead …", no --session-id) NOR its `ps eww` environment.
#   So any argv/env-scraping live-set is always empty for normally-launched
#   sessions and the reaper deletes the ACTIVE session's file. The fix is to
#   record a liveness token the reaper CAN observe: the OS pid of the long-lived
#   `claude`/`node` process that owns the session.
#
# Why not $$ or $PPID directly: a Bash tool-call (and thus the toggle) is an
#   ephemeral `zsh -c …` whose parent ($PPID) is itself a short-lived `zsh -c`
#   wrapper that exits the instant the call returns. Verified on the dev box:
#   the toggle's $PPID was 49641 (/bin/zsh -c …), gone moments later; its
#   grandparent 15140 was the `claude` process that lives for the whole session.
#   So we walk ancestry up from $PPID to the first claude/node process.
#
# Output: the owner PID on success; nothing (empty) if no claude/node ancestor
#   is found within the walk bound (caller treats empty as "unknown owner").
# Never fails the caller (no `set -e` surprises): always returns 0.
_session_owner_pid() {
    local pid="${PPID:-}"
    local hops=0
    local comm
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && "$hops" -lt 12 ]]; do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
        case "$comm" in
            *claude*|*node*)
                printf '%s' "$pid"
                return 0
                ;;
        esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
        hops=$(( hops + 1 ))
    done
    return 0
}

# Internal: trim all whitespace from a value
_trim_ws() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# _resolve_mode: print the winning mode value (trimmed).
# Side-channel: sets RESOLVED_MODE_SOURCE to the winning layer name
# (session|project|global|seed|default) so callers can inspect it without
# walking the chain a second time.
_resolve_mode() {
    local raw=""
    RESOLVED_MODE_SOURCE=""

    # 1. session layer — only if id is a well-formed UUID
    local _sid="${CLAUDE_CODE_SESSION_ID:-}"
    if [[ -n "$_sid" ]]; then
        if _validate_session_id "$_sid"; then
            local _sf="${STATE_DIR}/session/${_sid}"
            if [[ -f "$_sf" ]]; then
                # Read ONLY the first line: the session file is
                #   line 1: mode (on|off)
                #   line 2: pid:<owner>   (liveness token for the reaper; optional)
                # Legacy single-line files (just "on"/"off") read identically.
                IFS= read -r raw < "$_sf" || raw=""
                RESOLVED_MODE_SOURCE="session"
            fi
        else
            echo "[claude-remote] WARNING: CLAUDE_CODE_SESSION_ID '${_sid}' is not a well-formed UUID — session layer skipped" >&2
        fi
    fi

    # 2. project-local (preserve existing behaviour — CLAUDE_PROJECT_DIR guard)
    if [[ -z "$RESOLVED_MODE_SOURCE" ]] && [[ -n "$CLAUDE_PROJECT_DIR" && -f "$CLAUDE_PROJECT_DIR/.claude-remote-mode" ]]; then
        raw="$(< "$CLAUDE_PROJECT_DIR/.claude-remote-mode")"
        RESOLVED_MODE_SOURCE="project"
    fi

    # 3. global file
    if [[ -z "$RESOLVED_MODE_SOURCE" ]] && [[ -f "$STATE_DIR/mode" ]]; then
        raw="$(< "$STATE_DIR/mode")"
        RESOLVED_MODE_SOURCE="global"
    fi

    # 4. env seed
    if [[ -z "$RESOLVED_MODE_SOURCE" ]] && [[ -n "$CLAUDE_REMOTE_MODE" ]]; then
        raw="$CLAUDE_REMOTE_MODE"
        RESOLVED_MODE_SOURCE="seed"
    fi

    # 5. default
    if [[ -z "$RESOLVED_MODE_SOURCE" ]]; then
        raw="on"
        RESOLVED_MODE_SOURCE="default"
    fi

    _trim_ws "$raw"
}

# _resolve_mode_source: print the layer name that won (session|project|global|seed|default).
# Delegates to _resolve_mode (single precedence walker) and reads the side-channel.
_resolve_mode_source() {
    _resolve_mode >/dev/null
    echo "$RESOLVED_MODE_SOURCE"
}

# _session_name_for: derive the mutagen session name for a given absolute path.
# The name is "claude-remote-" followed by the path with all non-alphanumeric/hyphen
# characters replaced by hyphens, with leading and trailing hyphens stripped.
# Both sync-start.sh and remote-shell.sh call this — single source of truth.
_session_name_for() {
    local path="$1"
    echo "claude-remote-$(echo "$path" | tr -c '[:alnum:]-' '-' | sed 's/^-//;s/-$//')"
}

# _resolve_url: print effective host (url file if valid, else config.sh REMOTE_HOST)
_resolve_url() {
    local url_file="${STATE_DIR}/url"
    if [[ -f "$url_file" ]]; then
        local raw
        raw="$(< "$url_file")"
        raw="$(_trim_ws "$raw")"
        if [[ -n "$raw" ]]; then
            echo "$raw"
            return
        fi
    fi
    echo "${REMOTE_HOST:-<not set>}"
}
