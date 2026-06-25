#!/usr/bin/env bats
#
# toggle.bats — tests for the file-backed mode toggle in claude-remote
#
# Run with: bats tests/toggle.bats
#
# Tests exercised (no network calls — ssh/mutagen/osascript/ps are stubbed):
#   AC1  — mode=off -> local; mode=on -> remote (stubbed ssh sentinel)
#   AC2  — 4-case precedence: project-local > global > env seed > default(on)
#   AC9  — malformed/empty/whitespace mode -> local + warning on stderr
#   AC10 — off path writes pwd_file
#   AC11 — empty/whitespace url file -> no host override
#   Trim — CRLF and tab trimmed correctly
#   PS-AC1  — session > project-local
#   PS-AC2  — two sessions same STATE_DIR get independent routing
#   PS-AC3  — no session file → old precedence unchanged
#   PS-AC7  — injection read-side: malformed ids blocked, unset/empty silent
#   Reaper  — dead session files removed, live ones kept, 2nd run no-op
#

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
REMOTE_SHELL="$REPO_ROOT/scripts/remote-shell.sh"
SESSION_REAP="$REPO_ROOT/scripts/session-reap.sh"
# NOTE: the toggle script (claude-remote-toggle.sh) and its unit tests used to
# live here. It now ships as the standalone /claude-remote codex skill's
# toggle.sh (outside this repo), so its unit tests moved with it. The tests
# below cover only the routing/resolution layer this repo still owns
# (remote-shell.sh, lib-mode.sh, session-reap.sh).

# Well-formed UUID used throughout session tests
VALID_SID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
VALID_SID_B="b2c3d4e5-f6a7-8901-bcde-f12345678901"

setup() {
    TMP="$(mktemp -d)"

    STATE_DIR="$TMP/state"
    mkdir -p "$STATE_DIR"

    STUB_BIN="$TMP/bin"
    mkdir -p "$STUB_BIN"

    # stub ssh: -O check -> exit 0; "exit 0" probe -> exit 0; else sentinel
    cat > "$STUB_BIN/ssh" <<'SSHEOF'
#!/usr/bin/env bash
for arg; do
    if [[ "$arg" == "-O" ]]; then exit 0; fi
    if [[ "$arg" == "exit 0" ]]; then exit 0; fi
done
echo "__REMOTE_STUB_CALLED__"
echo "__CLAUDE_REMOTE_PWD__"
echo "/stubbox/cwd"
SSHEOF
    chmod +x "$STUB_BIN/ssh"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/mutagen"
    chmod +x "$STUB_BIN/mutagen"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/osascript"
    chmod +x "$STUB_BIN/osascript"
}

teardown() {
    rm -rf "$TMP"
}

# Run remote-shell.sh with controlled env.
# Usage: _rsh [KEY=val ...] -- [args]
# Sets: RS_OUTPUT, RS_STDERR, RS_STATUS
_rsh() {
    local extra_env=()
    while [[ "${1:-}" != "--" && $# -gt 0 ]]; do
        extra_env+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift

    local sf="$TMP/stderr_$$_$RANDOM"
    RS_OUTPUT="$(
        env "${extra_env[@]}" \
            PATH="$STUB_BIN:$PATH" \
            CLAUDE_REMOTE_STATE_DIR="$STATE_DIR" \
            CLAUDE_REMOTE_SSH="$STUB_BIN/ssh" \
            bash "$REMOTE_SHELL" "$@" \
        2>"$sf"
    )" || RS_STATUS=$?
    RS_STATUS="${RS_STATUS:-0}"
    RS_STDERR="$(cat "$sf")"
}

# ---------------------------------------------------------------------------
# AC1: mode=off -> local; mode=on -> remote
# ---------------------------------------------------------------------------

@test "AC1a: global mode=off routes locally (no remote sentinel)" {
    printf 'off\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo HELLO"
    [[ "$RS_OUTPUT" == *"HELLO"* ]]
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
}

@test "AC1b: global mode=on routes to remote (stub sentinel present)" {
    printf 'on\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo HELLO"
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
}

# ---------------------------------------------------------------------------
# AC2: 4-case precedence matrix
# ---------------------------------------------------------------------------

@test "AC2a: project-local file beats global file (local=off overrides global=on)" {
    printf 'on\n'  > "$STATE_DIR/mode"
    mkdir -p "$TMP/project"
    printf 'off\n' > "$TMP/project/.claude-remote-mode"
    _rsh "CLAUDE_PROJECT_DIR=$TMP/project" -- -c "echo X"
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
}

@test "AC2b: global file beats env seed (global=off overrides CLAUDE_REMOTE_MODE=on)" {
    printf 'off\n' > "$STATE_DIR/mode"
    _rsh "CLAUDE_REMOTE_MODE=on" -- -c "echo X"
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
}

@test "AC2c: env seed beats built-in default (CLAUDE_REMOTE_MODE=off with no files)" {
    local empty_state="$TMP/empty_$$"
    mkdir -p "$empty_state"
    RS_OUTPUT="$(
        PATH="$STUB_BIN:$PATH" \
        CLAUDE_REMOTE_STATE_DIR="$empty_state" \
        CLAUDE_REMOTE_SSH="$STUB_BIN/ssh" \
        CLAUDE_REMOTE_MODE="off" \
        bash "$REMOTE_SHELL" -c "echo X" 2>/dev/null
    )" || true
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
}

@test "AC2d: built-in default=on when no files and no env (routes remote)" {
    local empty_state="$TMP/empty2_$$"
    mkdir -p "$empty_state"
    RS_OUTPUT="$(
        PATH="$STUB_BIN:$PATH" \
        CLAUDE_REMOTE_STATE_DIR="$empty_state" \
        CLAUDE_REMOTE_SSH="$STUB_BIN/ssh" \
        bash "$REMOTE_SHELL" -c "echo X" 2>/dev/null
    )" || true
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
}

# ---------------------------------------------------------------------------
# AC9: malformed/empty/whitespace mode -> local + WARNING on stderr
# ---------------------------------------------------------------------------

@test "AC9a: mode='onn' routes locally and emits WARNING with 'unrecognized mode'" {
    printf 'onn\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" == *"WARNING"* ]]
    [[ "$RS_STDERR" == *"unrecognized mode"* ]]
}

@test "AC9b: whitespace-only mode routes locally and emits WARNING" {
    printf '   \n' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" == *"WARNING"* ]]
}

@test "AC9c: mode='yes' routes locally and emits WARNING" {
    printf 'yes\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" == *"WARNING"* ]]
}

@test "AC9d: empty mode file routes locally and emits WARNING" {
    printf '' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" == *"WARNING"* ]]
}

# ---------------------------------------------------------------------------
# Trim fix: CRLF and tab must be stripped
# ---------------------------------------------------------------------------

@test "Trim-CRLF: mode file with CRLF line ending (on\\r\\n) routes remote, no WARNING" {
    printf 'on\r\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

@test "Trim-TAB: mode file with trailing tab (on\\t\\n) routes remote, no WARNING" {
    printf 'on\t\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

# ---------------------------------------------------------------------------
# AC10: mode=off still writes pwd_file
# ---------------------------------------------------------------------------

@test "AC10: mode=off writes pwd_file when command includes the pwd suffix" {
    printf 'off\n' > "$STATE_DIR/mode"
    local pwd_file="$TMP/pwd_out"

    PATH="$STUB_BIN:$PATH" \
    CLAUDE_REMOTE_STATE_DIR="$STATE_DIR" \
    CLAUDE_REMOTE_SSH="$STUB_BIN/ssh" \
        bash "$REMOTE_SHELL" -c "echo HELLO && pwd -P >| $pwd_file" \
        >/dev/null 2>/dev/null || true

    [[ -f "$pwd_file" ]] || { echo "FAIL: pwd_file not created"; false; }
    local written; written="$(cat "$pwd_file")"
    [[ -n "$written" ]] || { echo "FAIL: pwd_file empty"; false; }
}

# ---------------------------------------------------------------------------
# AC11: empty/whitespace url file -> no REMOTE_HOST override
# ---------------------------------------------------------------------------

@test "AC11a: empty url file does not override REMOTE_HOST (remote routing works)" {
    printf '' > "$STATE_DIR/url"
    printf 'on\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

@test "AC11b: whitespace-only url file does not override REMOTE_HOST" {
    printf '   \n' > "$STATE_DIR/url"
    printf 'on\n' > "$STATE_DIR/mode"
    _rsh -- -c "echo X"
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

# ===========================================================================
# SESSION LAYER TESTS
# ===========================================================================

# ---------------------------------------------------------------------------
# PS-AC1: session=off beats project-local=on
# ---------------------------------------------------------------------------

@test "PS-AC1: session=off beats project-local=on -> routes locally" {
    # project-local says on
    mkdir -p "$TMP/proj1"
    printf 'on\n' > "$TMP/proj1/.claude-remote-mode"
    # session says off
    mkdir -p "$STATE_DIR/session"
    printf 'off\n' > "$STATE_DIR/session/$VALID_SID"

    _rsh "CLAUDE_CODE_SESSION_ID=$VALID_SID" "CLAUDE_PROJECT_DIR=$TMP/proj1" -- -c "echo X"
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

# ---------------------------------------------------------------------------
# PS-AC2: two sessions with same STATE_DIR/project get independent routing
# ---------------------------------------------------------------------------

@test "PS-AC2: session A=on routes remote; session B=off routes local (same STATE_DIR)" {
    # global=off so without session files both would be local
    printf 'off\n' > "$STATE_DIR/mode"
    mkdir -p "$STATE_DIR/session"
    printf 'on\n'  > "$STATE_DIR/session/$VALID_SID"
    printf 'off\n' > "$STATE_DIR/session/$VALID_SID_B"

    # Session A: on -> remote
    _rsh "CLAUDE_CODE_SESSION_ID=$VALID_SID" -- -c "echo A"
    local out_a="$RS_OUTPUT"

    # Session B: off -> local
    _rsh "CLAUDE_CODE_SESSION_ID=$VALID_SID_B" -- -c "echo B"
    local out_b="$RS_OUTPUT"

    [[ "$out_a" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$out_b" != *"__REMOTE_STUB_CALLED__"* ]]
}

# ---------------------------------------------------------------------------
# PS-AC3: no session file -> old precedence unchanged
# ---------------------------------------------------------------------------

@test "PS-AC3: no session file -> project-local beats global (old precedence)" {
    # global=on, project=off, no session file for this id
    printf 'on\n'  > "$STATE_DIR/mode"
    mkdir -p "$TMP/proj3"
    printf 'off\n' > "$TMP/proj3/.claude-remote-mode"
    # session dir exists but no file for VALID_SID
    mkdir -p "$STATE_DIR/session"

    _rsh "CLAUDE_CODE_SESSION_ID=$VALID_SID" "CLAUDE_PROJECT_DIR=$TMP/proj3" -- -c "echo X"
    # project=off wins over global=on -> local
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

# NOTE: PS-AC4/PS-AC4b (enable/disable --session writes) and PS-AC5a/PS-AC5b
# (status source lines) were unit tests of the toggle script's write/status
# verbs. They moved out with the toggle script (now the /claude-remote codex
# skill). The read-side behaviour they depended on — session-file precedence
# and source resolution — is still covered here via remote-shell.sh (PS-AC1,
# PS-AC2, PS-AC3) and lib-mode.sh.

# ---------------------------------------------------------------------------
# PS-AC7: injection read-side — malformed ids blocked
# ---------------------------------------------------------------------------

@test "PS-AC7a: unset CLAUDE_CODE_SESSION_ID -> session layer silently skipped, no WARNING" {
    printf 'on\n' > "$STATE_DIR/mode"
    # Explicitly unset the var
    _rsh -- -c "echo X"
    # Routes remote via global=on
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

@test "PS-AC7b: empty CLAUDE_CODE_SESSION_ID -> session layer silently skipped, no WARNING" {
    printf 'on\n' > "$STATE_DIR/mode"
    _rsh "CLAUDE_CODE_SESSION_ID=" -- -c "echo X"
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

@test "PS-AC7c: path-traversal id '../mode' -> WARNING emitted, session layer blocked" {
    # global=on, so without session layer the gate would route remote
    # The traversal id '../mode' if allowed would try to read session/../mode (= global mode file)
    # With global=on that would still route remote — so set global=off for this test:
    # if traversal were allowed and read 'off' via session/../mode, it would route local.
    # We instead test: put 'on' in global, set id='../mode'. With traversal allowed,
    # it would try to read session/../mode = global = 'on' -> remote.
    # With traversal blocked (validator rejects), session is skipped -> global 'on' -> remote.
    # That's indistinguishable. Instead: put 'off' in global and 'on' in a file at
    # session/../mode (which is just the global file). If traversal read it as 'on',
    # we'd get remote. But validator blocks traversal -> falls to global 'off' -> local.
    printf 'off\n' > "$STATE_DIR/mode"
    mkdir -p "$STATE_DIR/session"
    # The traversal would reach session/../mode which is the global 'off' file anyway,
    # but the validator must reject the id and emit a WARNING.
    _rsh "CLAUDE_CODE_SESSION_ID=../mode" -- -c "echo X"
    # Session layer blocked -> global=off -> local
    [[ "$RS_OUTPUT" != *"__REMOTE_STUB_CALLED__"* ]]
    # Must emit WARNING about malformed id
    [[ "$RS_STDERR" == *"WARNING"* ]]
    # Warning must mention the session id
    [[ "$RS_STDERR" == *"../mode"* ]]
}

@test "PS-AC7d: slash-containing id 'a/b' -> WARNING emitted, session layer blocked" {
    printf 'on\n' > "$STATE_DIR/mode"
    _rsh "CLAUDE_CODE_SESSION_ID=a/b" -- -c "echo X"
    # global=on, session skipped -> remote
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" == *"WARNING"* ]]
    [[ "$RS_STDERR" == *"a/b"* ]]
}

@test "PS-AC7e: well-formed id with no session file -> silently skips to global, no WARNING" {
    printf 'on\n' > "$STATE_DIR/mode"
    mkdir -p "$STATE_DIR/session"
    # No file for VALID_SID under session/
    _rsh "CLAUDE_CODE_SESSION_ID=$VALID_SID" -- -c "echo X"
    [[ "$RS_OUTPUT" == *"__REMOTE_STUB_CALLED__"* ]]
    [[ "$RS_STDERR" != *"WARNING"* ]]
}

# NOTE: PS-AC8/PS-AC9/PS-AC10 were toggle-script write-side unit tests
# (enable/disable/clear --session, malformed-id rejection, global-file
# immutability). They moved out with the toggle script (now the /claude-remote
# codex skill). The injection-blocking they relied on is still covered on the
# read side here via remote-shell.sh (PS-AC7c, PS-AC7d).

# ---------------------------------------------------------------------------
# Reaper: dead session files removed; live ones kept; 2nd run no-op
# ---------------------------------------------------------------------------

# Liveness for the reaper is the OWNER PID recorded on line 2 of the session
# file ("pid:<n>"), NOT the UUID in some process's argv. These tests exercise
# that real mechanism with genuine OS processes:
#   - "alive" owner  = a real backgrounded `sleep` whose pid is live (kill -0 ok)
#   - "dead"  owner  = a pid we started, killed, and reaped (kill -0 fails)
# A file claiming a live owner must survive even when aged past the grace
# window; a file claiming a dead owner (or no owner at all) must be reaped once
# past the grace window.

# Backdate a session file's mtime past the grace window (macOS or Linux).
_age_past_grace() {
    touch -t "$(date -v-120S +%Y%m%d%H%M.%S 2>/dev/null || date -d '-120 seconds' +%Y%m%d%H%M.%S)" \
        "$1" 2>/dev/null || true
}

# Print a pid that is guaranteed DEAD: start a process, kill it, reap it.
_make_dead_pid() {
    local p
    sleep 300 & p=$!
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    printf '%s' "$p"
}

_run_reap() {
    PATH="$STUB_BIN:$PATH" \
    CLAUDE_REMOTE_STATE_DIR="$STATE_DIR" \
    bash "$SESSION_REAP"
}

@test "Reaper: keeps file with LIVE owner pid, reaps file with DEAD owner pid, 2nd run no-op" {
    local live_id="$VALID_SID"
    local dead_id="dead1234-dead-dead-dead-deaddeaddead"

    # A real live owner process for the live file.
    local alive_pid
    sleep 300 & alive_pid=$!

    # A guaranteed-dead owner for the dead file.
    local dead_pid
    dead_pid="$(_make_dead_pid)"

    mkdir -p "$STATE_DIR/session"
    printf 'on\npid:%s\n' "$alive_pid" > "$STATE_DIR/session/$live_id"
    printf 'on\npid:%s\n' "$dead_pid"  > "$STATE_DIR/session/$dead_id"

    # Age BOTH past the grace window: liveness must come from kill -0, not age.
    _age_past_grace "$STATE_DIR/session/$live_id"
    _age_past_grace "$STATE_DIR/session/$dead_id"

    _run_reap

    # Live-owner file survives despite being old; dead-owner file is gone.
    [[ -f "$STATE_DIR/session/$live_id" ]]
    [[ ! -f "$STATE_DIR/session/$dead_id" ]]

    # 2nd run is a no-op: live still present, nothing left to reap.
    local reap_out2
    reap_out2="$(_run_reap)"
    [[ -f "$STATE_DIR/session/$live_id" ]]
    [[ "$reap_out2" == *"reaped 0"* ]]

    kill "$alive_pid" 2>/dev/null || true
}

@test "Reaper: legacy file (no pid line) past grace is reaped" {
    # Files written before the PID fix have no observable owner — genuine
    # orphans. Past the grace window they must be reaped (mirrors the stale
    # Jun-17 files that motivated this fix).
    local legacy_id="$VALID_SID"

    mkdir -p "$STATE_DIR/session"
    printf 'on\n' > "$STATE_DIR/session/$legacy_id"
    _age_past_grace "$STATE_DIR/session/$legacy_id"

    _run_reap

    [[ ! -f "$STATE_DIR/session/$legacy_id" ]]
}

@test "Reaper: dead-owner file INSIDE grace window survives (TOCTOU guard)" {
    # A file just written (young) whose owner pid is already dead must still be
    # spared — the grace window guards the write-mid-reap race.
    local young_id="$VALID_SID"

    local dead_pid
    dead_pid="$(_make_dead_pid)"

    mkdir -p "$STATE_DIR/session"
    printf 'on\npid:%s\n' "$dead_pid" > "$STATE_DIR/session/$young_id"
    # Do NOT backdate — file is fresh, inside the 60s grace window.

    local reap_out
    reap_out="$(_run_reap)"

    [[ -f "$STATE_DIR/session/$young_id" ]]
    [[ "$reap_out" == *"reaped 0"* ]]
}

@test "Reaper: mode line 1 still resolves correctly with a pid line present" {
    # The two-line format must not break mode resolution: line 1 is the mode,
    # line 2 (pid:) is liveness metadata only.
    mkdir -p "$STATE_DIR/session"
    printf 'off\npid:12345\n' > "$STATE_DIR/session/$VALID_SID"

    # Resolve via the canonical resolver in lib-mode.sh.
    run env -u CLAUDE_PROJECT_DIR -u CLAUDE_REMOTE_MODE \
        CLAUDE_REMOTE_STATE_DIR="$STATE_DIR" \
        CLAUDE_CODE_SESSION_ID="$VALID_SID" \
        bash -c 'STATE_DIR="$CLAUDE_REMOTE_STATE_DIR"; CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"; CLAUDE_REMOTE_MODE="${CLAUDE_REMOTE_MODE:-}"; source "'"$REPO_ROOT"'/scripts/lib-mode.sh"; printf "%s|%s" "$(_resolve_mode)" "$(_resolve_mode_source)"'
    [[ "$output" == "off|session" ]]
}

# ===========================================================================
# Toggle-script unit tests — moved out of this repo
# ===========================================================================
#
# A suite of "Toggle-AC*" cases used to unit-test the toggle helper script
# (its on/off/status write+status verbs and UUID/traversal rejection). That
# script no longer ships from this repo — it became toggle.sh inside the
# standalone /claude-remote codex skill, so its unit tests moved with it to
# that skill's own suite.
#
# What this repo still owns — and still tests above — is the routing and mode
# RESOLUTION layer those verbs wrote into:
#   - remote-shell.sh  — AC1/AC2/AC9/AC10/AC11, Trim, PS-AC1/2/3/7 (precedence,
#     session-file resolution, malformed-id blocking on the read side)
#   - lib-mode.sh      — the canonical mode/source/url resolver
#   - session-reap.sh  — Reaper
#
# No toggle-runner helper or removed-script path reference remains here.
