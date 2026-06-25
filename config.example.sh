# Claude Remote Configuration
# Copy this file to config.sh and edit with your values

# SSH connection to remote machine
REMOTE_HOST="ubuntu@your-ec2-instance.amazonaws.com"

# Root on remote where CWD mirrors are synced (local /abs/path → REMOTE_MIRROR_ROOT/abs/path)
# Only used when PATH_IDENTITY=false (legacy/default mode).
REMOTE_MIRROR_ROOT="/home/ubuntu/claude-remote-mirror"

# PATH_IDENTITY: when true, sync to the identical absolute path on the remote box
# (e.g. /Users/USER/workspace/... exists on the box at exactly that path).
# Requires the box to have /Users/<user> created and owned by the ssh user;
# setup.sh can do this for you when PATH_IDENTITY=true.
# When false (default), paths are mirrored under REMOTE_MIRROR_ROOT.
PATH_IDENTITY="false"

# ---------------------------------------------------------------------------
# CLAUDE_REMOTE_MODE — LAUNCH-TIME SEED ONLY
#
# This env var is the lowest-priority input to the mode toggle.  It is read
# once when remote-shell.sh starts (per Bash call) but CANNOT change the
# routing mid-session because Claude Code re-execs $SHELL each call: any
# "export CLAUDE_REMOTE_MODE=off" a child shell runs is gone by the next call.
#
# To toggle routing mid-session, use the /claude-remote skill inside any Claude session:
#
#   /claude-remote on     # write per-session mode=on
#   /claude-remote off    # write per-session mode=off
#   /claude-remote status # show resolved mode + source + url
#
# CLAUDE_REMOTE_MODE in the environment is still honoured as a seed when no
# state file exists (precedence: project-local file > global file > this env
# var > built-in default "on").
# ---------------------------------------------------------------------------
# CLAUDE_REMOTE_MODE="on"   # uncomment to seed a session default

# ---------------------------------------------------------------------------
# CLAUDE_REMOTE_STATE_DIR — override the state directory (default: ~/.claude-remote)
# ---------------------------------------------------------------------------
# CLAUDE_REMOTE_STATE_DIR="$HOME/.claude-remote"
