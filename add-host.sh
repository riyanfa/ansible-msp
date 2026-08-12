#!/usr/bin/env bash
# Onboard one host without editing any inventory file.
#
#   ./add-host.sh <customer> <host> [login_user] [bootstrap_key] [-- extra args]
#
#   ./add-host.sh clientB 192.168.1.50 root ~/.ssh/their-key.pem
#   ./add-host.sh clientB 192.168.1.50 root              # no key -> prompts for password
#   ./add-host.sh clientB 192.168.1.50 ubuntu ~/.ssh/k.pem -- --check --diff
#
# Omit the key when the customer gave you a PASSWORD instead. Needs sshpass
# (apt install sshpass / dnf install sshpass). Add `-- --ask-become-pass`
# if that account also needs a password for sudo.
#
# The host is passed inline (-i 'host,') so onboarding.ini is never touched.
# The customer's managed.ini is passed too, which is what makes group_vars load.
# On success the host is appended to that managed.ini automatically.
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 1; }

CUSTOMER="${1:-}"; HOST="${2:-}"
[ -z "$CUSTOMER" ] || [ -z "$HOST" ] && usage
shift 2

# Optional positionals, stopping at `--` so it is never mistaken for a value.
LOGIN_USER="root"; BOOT_KEY=""
if [ -n "${1:-}" ] && [ "${1:-}" != "--" ]; then LOGIN_USER="$1"; shift; fi
if [ -n "${1:-}" ] && [ "${1:-}" != "--" ]; then BOOT_KEY="$1";   shift; fi
[ "${1:-}" = "--" ] && shift || true

cd "$(dirname "$0")"
# Customer data lives outside the clone — see new-customer.sh.
DATA_ROOT="${MSP_DATA_ROOT:-$HOME/customers}"
DATA="${DATA_ROOT}/${CUSTOMER}"
[ -f "$DATA/group_vars/all.yml" ] || {
  echo "ERROR: $DATA/group_vars/all.yml not found."
  echo "       Known customers: $(ls -d "$DATA_ROOT"/*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  echo "       Create one with: ./new-customer.sh <slug> \"<Name>\" <egress-ip>"
  exit 1
}
[ -f "$DATA/managed.ini" ] || printf '[managed]\n' > "$DATA/managed.ini"

# Absolute path: a delegate_to task resolves relative paths against the
# delegate's home directory, not the playbook's working directory.
MANAGED_ABS="$(cd "$DATA" && pwd)/managed.ini"

EXTRA=(-e "target_hosts=${HOST}"
       -e "ansible_user=${LOGIN_USER}"
       -e "managed_inventory=${MANAGED_ABS}")

ASK=()
if [ -n "$BOOT_KEY" ]; then
  BOOT_KEY="${BOOT_KEY/#\~/$HOME}"
  [ -f "$BOOT_KEY" ] || { echo "ERROR: key not found: $BOOT_KEY"; exit 1; }
  # ssh refuses group/world-readable keys
  perms=$(stat -c '%a' "$BOOT_KEY" 2>/dev/null || stat -f '%A' "$BOOT_KEY")
  [ "$perms" = "600" ] || { echo "Fixing permissions on $BOOT_KEY"; chmod 600 "$BOOT_KEY"; }
  EXTRA+=(-e "ansible_ssh_private_key_file=${BOOT_KEY}")
  # offer only this key: agents holding several customer keys trip MaxAuthTries
  EXTRA+=(-e "ansible_ssh_common_args=-o IdentitiesOnly=yes")
else
  # Password auth. Ansible shells out to sshpass for this; without it the run
  # fails with a misleading "Failed to connect to the host via ssh".
  command -v sshpass >/dev/null || {
    echo "ERROR: no bootstrap key given, so password auth is needed — but sshpass is missing."
    echo "       apt install sshpass   |   dnf install sshpass   (EPEL on RHEL)"
    echo "       Or pass the key as the 4th argument."
    exit 1
  }
  ASK=(--ask-pass)
  echo "No key given — you will be prompted for ${LOGIN_USER}'s SSH password."
fi

echo "Onboarding ${HOST} for ${CUSTOMER} (login as ${LOGIN_USER})"
ansible-playbook -i "$DATA/managed.ini" -i "${HOST}," playbooks/onboard.yml \
  "${EXTRA[@]}" ${ASK[@]+"${ASK[@]}"} "$@"

# ansible-playbook exits 0 even when no hosts matched, so verify the outcome
# rather than trusting the exit code.
if ! grep -qx "${HOST}" "$DATA/managed.ini"; then
  echo
  echo "WARNING: ${HOST} is not in ${DATA}/managed.ini — onboarding did not complete."
  echo "         (a --check run will also show this; otherwise scroll up for the failure)"
  exit 1
fi

cat <<EOF

Added to ${DATA}/managed.ini. Next:
  ansible-playbook -i ${DATA}/managed.ini playbooks/verify.yml
  shred -u ${BOOT_KEY:-<bootstrap key>}
EOF
