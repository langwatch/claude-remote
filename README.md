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
│  │ ~/Projects/  │◀──▶│   Mutagen    │◀─────────────┼────────┐      │
│  │   remote/    │    │ (bidirectional sync)        │        │      │
│  └──────────────┘    └──────────────┘              │        │      │
└────────────────────────────────────────────────────┼────────┼──────┘
                                                     │        │
                                                     ▼        ▼
┌────────────────────────────────────────────────────────────────────┐
│                      Remote Server (EC2)                           │
│  ┌──────────────┐    ┌──────────────────────────────────────┐     │
│  │   SSH        │    │  /home/ubuntu/Projects/               │     │
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
# Launch Claude with remote execution (uses DEFAULT_PROJECT from config)
claude-remote

# Or specify a path
claude-remote ~/Projects/remote/my-project
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
ssh-tmux         # SSH into remote with persistent tmux session
```

## Configuration

Edit `config.sh` (created by setup.sh):

```bash
# SSH connection to remote machine
REMOTE_HOST="ubuntu@your-ec2-instance.amazonaws.com"

# Directory on remote machine where commands will execute
REMOTE_DIR="/home/ubuntu/Projects"

# Local directory to sync with remote
LOCAL_MOUNT="$HOME/Projects/remote"

# Default project directory (optional, defaults to LOCAL_MOUNT)
DEFAULT_PROJECT="$LOCAL_MOUNT/my-project"
```

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
