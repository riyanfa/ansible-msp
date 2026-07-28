#!/usr/bin/env bash
# Set up a fresh control VM for one customer. Run as the ansible user, not root.
#
#   ./setup.sh <customer> <repo_url>
#   ./setup.sh clientB git@github.com:yourorg/ansible-msp.git
#
# Installs ansible+git, clones the repo (stable branch), generates this
# customer's management key if absent, and enables the repo-sync timer.
# Idempotent — safe to re-run.
set -euo pipefail

CUSTOMER="${1:-}"; REPO_URL="${2:-}"
[ -z "$CUSTOMER" ] || [ -z "$REPO_URL" ] && { sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 1; }
[ "$(id -u)" -eq 0 ] && { echo "ERROR: run as the ansible user, not root."; exit 1; }

REPO_DIR="$HOME/ansible-msp"
KEY="$HOME/.ssh/${CUSTOMER}_ansible"

echo "== 1/5 packages =="
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq ansible git
elif command -v dnf >/dev/null; then
  sudo dnf install -y -q ansible-core git
else
  echo "ERROR: neither apt nor dnf found."; exit 1
fi

echo "== 2/5 repo (branch: stable) =="
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only origin stable
else
  git clone -b stable "$REPO_URL" "$REPO_DIR"
fi
[ -d "$REPO_DIR/customers/$CUSTOMER" ] || \
  echo "WARNING: customers/$CUSTOMER/ not in repo yet — create and push it."

echo "== 3/5 management key =="
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ -f "$KEY" ]; then
  echo "exists: $KEY"
else
  ssh-keygen -t ed25519 -N "" -C "ansible-${CUSTOMER}" -f "$KEY"
fi

echo "== 4/5 repo-sync timer =="
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/control/repo-sync.service" "$REPO_DIR/control/repo-sync.timer" \
   "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now repo-sync.timer
loginctl enable-linger "$USER"

echo "== 5/5 commit hook =="
cp "$REPO_DIR/hooks/pre-commit" "$REPO_DIR/.git/hooks/pre-commit"
chmod +x "$REPO_DIR/.git/hooks/pre-commit"

cat <<EOF

Done. This VM manages: $CUSTOMER

Next:
  1. Put this PUBLIC key into customers/$CUSTOMER/group_vars/all.yml
     (mgmt_authorized_keys), with this VM's egress IP in control_node_ips:

     $(cat "$KEY.pub")

  2. Commit + push that from your workstation (control VMs are read-only).
  3. Onboard hosts:
     cd $REPO_DIR
     ansible-playbook -i customers/$CUSTOMER/onboarding.ini playbooks/onboard.yml
EOF
