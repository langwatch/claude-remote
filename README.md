# Claude Remote

Run Claude Code locally with the UI on your machine, but execute all commands on a remote server.

**Why?** Claude Code can be CPU-intensive (TypeScript compilation, tests, file operations). This setup lets you:
- Keep your local machine fast and responsive
- Use a powerful remote server (EC2, etc.) for heavy lifting
- Maintain low-latency typing since the Claude UI runs locally

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Your Mac (Local)                            │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────────┐    │
│  │ Claude Code  │───▶│ remote-shell │───▶│ SSH ControlMaster  │    │
│  │   (UI/TUI)   │    │   wrapper    │    │ (persistent conn)  │    │
│  └──────────────┘    └──────────────┘    └─────────┬──────────┘    │
│         │                                          │                │
│         ▼                                          │                │
│  ┌──────────────┐    ┌──────────────┐              │                │
│  │ Any local    │◀──▶│   Mutagen    │◀─────────────┼────────┐      │
│  │  directory   │    │ (bidirectional sync)        │        │      │
│  └──────────────┘    └──────────────┘              │        │      │
└────────────────────────────────────────────────────┼────────┼──────┘
                                                     │        │
                                                     ▼        ▼
┌────────────────────────────────────────────────────────────────────┐
│                      Remote Server (EC2)                           │
│  ┌──────────────┐    ┌──────────────────────────────────────┐     │
│  │   SSH        │    │  REMOTE_MIRROR_ROOT/<abs-path>/       │     │
│  │   Server     │───▶│  (your actual files & execution)     │     │
│  └──────────────┘    └──────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────┘
```

### How it works

1. **Shell Interception**: Claude Code uses `$SHELL` to execute commands. We provide a custom shell wrapper that:
   - Intercepts all commands Claude tries to run
   - Forwards them via SSH to the remote server
   - Maps paths between local and remote automatically
   - Returns output and exit codes transparently

2. **Bidirectional File Sync**: [Mutagen](https://mutagen.io/) keeps files in sync between local and remote:
   - Files are **real local files** - instant access for Claude's Read/Write/Edit/Glob/Grep tools
   - Works with any local editor (VS Code, Cursor, etc.)
   - Before each remote command, sync is flushed to ensure consistency
   - Smart ignore patterns for `node_modules`, `.venv`, `.cache`, etc.

3. **SSH Multiplexing**: Uses SSH ControlMaster for persistent connections, avoiding SSH handshake overhead on every command.

4. **Local Fallback**: When the remote server is unreachable (VPN off, network issues):
   - Automatically falls back to local execution
   - Shows macOS notification on state changes
   - Reminds you every 5 minutes if still offline
   - Seamlessly switches back when remote is available

### Why Mutagen sync instead of SSHFS?

We tried SSHFS (remote filesystem mounting) first, but switched to Mutagen for several reasons:

| Aspect | SSHFS (mounting) | Mutagen (sync) |
|--------|------------------|----------------|
| **File access speed** | Network latency on every operation | Instant (files are local) |
| **Glob/Grep/Search** | Slow - must traverse remote FS | Fast - operates on local files |
| **Editor support** | Works but can be laggy | Full native speed |
| **Offline work** | Broken when disconnected | Files available locally |
| **Large repos** | Sluggish with many files | Only syncs what changed |

The tradeoff is disk space (files exist in both places) and sync delay, but in practice Mutagen syncs are near-instant and the UX is dramatically better.

## Requirements

- macOS (tested on macOS 15+)
- [Claude Code](https://claude.ai/code) installed
- SSH access to a remote server (with key-based auth)
- [Mutagen](https://mutagen.io/) for file synchronization

## Installation

### 1. Install dependencies

```bash
# Install Mutagen
brew install mutagen-io/mutagen/mutagen
```

### 2. Clone and setup

```bash
git clone https://github.com/langwatch/claude-remote.git ~/Projects/claude-remote
cd ~/Projects/claude-remote
./setup.sh
```

The setup script will:
- Prompt for your remote server details
- Create symlinks in `~/bin`
- Test your SSH connection

### 3. Ensure SSH key auth works

```bash
# If you haven't set up SSH keys
ssh-copy-id ubuntu@your-server.com
```

## Usage

```bash
# Launch Claude with remote execution (syncs current directory)
claude-remote
```

Once running, all Claude commands execute on the remote server:

```
❯ uname -a
Linux ip-10-0-3-248 6.14.0-1018-aws ... aarch64 GNU/Linux

❯ which pnpm python3
/home/ubuntu/.nvm/versions/node/v24.13.0/bin/pnpm
/usr/bin/python3
```

### Other commands

```bash
sync-start       # Start Mutagen sync (auto-started by claude-remote)
sync-stop        # Stop Mutagen sync
sync-status      # Check sync status
```

## Configuration

Edit `config.sh` (created by setup.sh):

```bash
REMOTE_HOST="ubuntu@your-ec2-instance.amazonaws.com"
REMOTE_MIRROR_ROOT="/home/ubuntu/claude-remote-mirror"
PATH_IDENTITY="false"   # set to "true" for identity-path mode (see below)
```

### PATH_IDENTITY mode

When `PATH_IDENTITY="true"`, files are synced to the **identical absolute path** on the remote box instead of being mirrored under `REMOTE_MIRROR_ROOT`. For example, `/Users/USER/workspace/myproject` on the Mac syncs to `/Users/USER/workspace/myproject` on the box — no path translation at all.

Benefits: git worktrees just work (no `.git` file rewriting needed), and any tool that embeds absolute paths in its output is correct on both sides without translation.

Requirements: the box must have `/Users/<localuser>` created and owned by the ssh user. `setup.sh` does this automatically when you answer `y` to the PATH_IDENTITY prompt. To do it manually:

```bash
# On the box (as a user with sudo):
sudo mkdir -p /Users/<localuser> && sudo chown ubuntu:ubuntu /Users /Users/<localuser>
```

`/Users` on the box is a plain directory — no bind-mount or special setup needed.

**Note:** only the directory you run `claude-remote` from is synced. One mutagen session is created per launch directory. Paths outside that tree are not present on the box.

### Toggling offload on/off

Toggling is driven by a companion **`/claude-remote` skill** that lives in your Claude Code skills directory at `~/.claude/skills/claude-remote/` (it ships separately from this repo). Once that skill is present, toggle from inside any Claude Code session:

```
/claude-remote on     # write per-session mode=on
/claude-remote off    # write per-session mode=off
/claude-remote status # print resolved mode, source, and url
```

Because `remote-shell.sh` is re-executed on every Bash tool call, the toggle takes effect on the **next command** — no Claude restart needed.

**Scope default is per-session:** `on`/`off` write a **per-session** file (not global). This means toggling on in one session does not affect other sessions. To set a persistent default, write the global file directly: `printf 'on\n' > ~/.claude-remote/mode`.

**How the toggle works (file-backed):** Claude Code re-execs `$SHELL` per Bash call, so environment variables set by a child shell are lost by the next call. The toggle writes a file that is re-read on every call instead:

```
~/.claude-remote/session/<id>  — per-session on|off (highest precedence)
~/.claude-remote/mode          — global on|off
~/.claude-remote/url           — ssh host string (e.g. ubuntu@10.0.3.56)
```

**Mode precedence (highest first):**
1. Per-session file `~/.claude-remote/session/<CLAUDE_CODE_SESSION_ID>`
2. Project-local file `$CLAUDE_PROJECT_DIR/.claude-remote-mode` (if `CLAUDE_PROJECT_DIR` is set)
3. Global file `~/.claude-remote/mode`
4. Env var `$CLAUDE_REMOTE_MODE` (launch-time seed — cannot change mid-session)
5. Built-in default: `on`

**Fail-safe:** any value other than exactly `on` routes **locally** and emits a warning to stderr. A corrupt toggle file can never silently SSH to a box.

**Wraps-not-activates:** when `claude-remote` launches, if `~/.claude-remote/mode` does not yet exist, the launcher seeds it with `off`. This means a fresh install is locally passthrough until you explicitly toggle on.

**Project-local override:** drop a `.claude-remote-mode` file in your project root (containing `on` or `off`) to override the global setting for that project only.

#### CLAUDE_REMOTE_MODE env var

The env var is still honoured as a **launch-time seed** (precedence step 4 above). It cannot toggle mid-session because child-shell exports do not survive across Bash calls:

```bash
# These do NOT toggle mid-session (child export is gone next call):
export CLAUDE_REMOTE_MODE=off    # ineffective after first Bash call
export CLAUDE_REMOTE_MODE=on

# Use the /claude-remote skill instead (inside a Claude session):
# /claude-remote off
# /claude-remote on
```

### Scoped sync sessions

Each `claude-remote` launch creates exactly one mutagen session for the launch directory. The session name is derived from the directory path (e.g. `claude-remote--Users-localuser-workspace-myproject`). Only that session is flushed before and after each remote command — other projects running in parallel are unaffected.

To clear zombie (halted/disconnected) sessions:

```bash
sync-reap
```

This lists all `claude-remote`-labelled sessions and terminates any whose status is Halted/Disconnected/errored or whose local alpha path no longer exists. Healthy sessions are left untouched.

### Sync ignore patterns

Edit `scripts/sync-start.sh` to customize which files are excluded from sync:

```bash
--ignore="node_modules"
--ignore=".venv"
--ignore=".cache"
--ignore=".next*"
# ... add more patterns as needed
```

## Tips

### Port Forwarding

If your remote server runs services (dev servers, databases, etc.), forward ports to access them locally:

```bash
# Forward a single port (e.g., Next.js dev server on 3000)
ssh -N -L 3000:localhost:3000 ubuntu@your-server.com

# Forward multiple ports
ssh -N -L 3000:localhost:3000 -L 5432:localhost:5432 ubuntu@your-server.com

# Run in background
ssh -fN -L 3000:localhost:3000 ubuntu@your-server.com
```

Now `http://localhost:3000` on your Mac connects to the remote server.

### Remote PATH setup

For fastest startup, add your tools directly to `~/.profile` on the remote machine instead of relying on slow shell initialization scripts like `nvm.sh`:

```bash
# On remote machine, add to ~/.profile:
export PATH=~/.nvm/versions/node/v24.13.0/bin:$PATH
export PATH=~/.local/bin:$PATH  # for uv, pipx, etc.
```

## Troubleshooting

### Commands not finding binaries (pnpm, node, etc.)

The remote shell sources `~/.profile`. Ensure your PATH is set there:

1. Check your remote `~/.profile` has the necessary paths
2. Verify: `ssh your-server "source ~/.profile && which pnpm"`

### Sync issues

```bash
# Check sync status
mutagen sync list

# Force flush sync
mutagen sync flush --label-selector=name=claude-remote

# Reset sync if stuck
sync-stop && sync-start
```

### SSH connection issues

```bash
# Test SSH
ssh -v your-server "echo ok"

# Clear SSH control socket if stuck
rm /tmp/ssh-claude-*
```

### Stale SSH control socket (commands hang)

If commands hang when your VPN reconnects or network changes, the SSH control socket may be stale. The script auto-detects this, but you can manually clear it:

```bash
rm /tmp/ssh-claude-*
```

## How the shell wrapper works

Claude Code invokes the shell like: `$SHELL -c -l "command"`

Our wrapper (`scripts/remote-shell.sh`):
1. Checks if remote is reachable (with 2-second timeout)
2. Falls back to local execution if not, with macOS notification
3. Flushes Mutagen sync before running remote commands
4. Maps local paths to remote paths in commands
5. Handles Claude's working directory tracking (`pwd -P >| /tmp/...`)
6. Forwards the command via SSH, sourcing `~/.profile` for PATH
7. Maps remote paths back to local in output
8. Flushes Mutagen sync after command completes
9. Preserves the exit code

## Contributing

PRs welcome! Some ideas:
- [ ] Support for Linux local machines
- [ ] Docker-based remote execution option
- [ ] Automatic port forwarding detection
- [ ] Sync conflict resolution UI

## License

MIT
