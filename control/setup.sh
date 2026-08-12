#!/usr/bin/env bash
# Prepare a control VM: packages, repo clone, auto-pull timer.
# Run as the ansible user, NOT root.
#
#   ./setup.sh <customer> <repo_url>
#   ./setup.sh clientB git@github.com:yourorg/ansible-msp.git
#
# This sets up the MACHINE. Adding the customer (key pair, group_vars,
# inventories) is new-customer.sh, which this prints at the end.
# Idempotent — safe to re-run.
set -euo pipefail

CUSTOMER="${1:-}"; REPO_URL="${2:-}"
[ -z "$CUSTOMER" ] || [ -z "$REPO_URL" ] && { sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 1; }
[ "$(id -u)" -eq 0 ] && { echo "ERROR: run as the ansible user, not root."; exit 1; }

REPO_DIR="$HOME/ansible-msp"   # public workflow repo, pull-only

echo "== 1/3 packages =="
# sshpass is only needed when a customer hands over a PASSWORD rather than a
# key — Ansible shells out to it for --ask-pass. Installing it up front avoids
# discovering it is missing mid-onboarding.
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq ansible git sshpass
elif command -v dnf >/dev/null; then
  sudo dnf install -y -q ansible-core git
  # On RHEL/Alma sshpass lives in EPEL, which may not be enabled. Don't fail
  # the whole setup for an optional dependency.
  sudo dnf install -y -q sshpass 2>/dev/null \
    || echo "  NOTE: sshpass unavailable (needs EPEL). Only required for password-based onboarding:"
  command -v sshpass >/dev/null \
    || echo "        sudo dnf install -y epel-release && sudo dnf install -y sshpass"
else
  echo "ERROR: neither apt nor dnf found."; exit 1
fi
for b in ansible-playbook git ssh-keygen; do
  command -v "$b" >/dev/null || { echo "ERROR: $b missing after install."; exit 1; }
done

echo "== 2/3 repo (branch: main) =="
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only origin main
else
  git clone "$REPO_URL" "$REPO_DIR"
fi
echo "== 3/3 repo-sync timer =="
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/control/repo-sync.service" "$REPO_DIR/control/repo-sync.timer" \
   "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now repo-sync.timer
loginctl enable-linger "$USER"

cat <<EOF

Control VM ready. Repo at $REPO_DIR, auto-pulling every 30 min.

Next — create the customer (generates the key pair and group_vars):

  cd $REPO_DIR
  ./new-customer.sh ${CUSTOMER} "<Display Name>" <this VM's egress IP>

Find the egress IP with:  ssh <a-customer-host> 'echo \$SSH_CLIENT'   (first field)
EOF
