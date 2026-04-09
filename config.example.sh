# Claude Remote Configuration
# Copy this file to config.sh and edit with your values

# SSH connection to remote machine
REMOTE_HOST="ubuntu@your-ec2-instance.amazonaws.com"

# Directory on remote machine where commands will execute
REMOTE_DIR="/home/ubuntu/Projects"

# Root on remote where CWD mirrors are synced (local /abs/path → REMOTE_MIRROR_ROOT/abs/path)
REMOTE_MIRROR_ROOT="/home/ubuntu/mirror"
