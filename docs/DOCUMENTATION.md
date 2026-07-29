# Ansible Customer Patching

Onboards customer Linux VMs into managed patching and keeps them patched.
One control VM per customer, on our premises, holding that customer's SSH key,
network config, and inventory.

Repo: https://github.com/riyanfa/ansible-msp

---

## What it does

Turns whatever credential a customer gives you (root password, cloud key, .pem)
into a standard, isolated management identity:

- `svc_ansible` account, password-locked, key-only
- key restricted to the control VM's IP (`from=`), so a leaked key is useless elsewhere
- sudo via a `visudo`-validated drop-in
- host recorded in that customer's managed inventory

Then assess/patch run against that identity.

## Architecture

![topology](diagrams/topology.png)

- **Public repo** — playbooks only, no customer data. Control VMs auto-pull `main` every 30 min.
- **Control VM** — one per customer. Holds the only copy of that customer's key and inventory.
- **Customer hosts** — reachable over SSH (VPN/bastion configured on the control VM, not here).

![lifecycle](diagrams/lifecycle.png)

A host is in `onboarding.ini` or `managed.ini`, never both. `onboard.yml` moves it.

## Requirements

- Control VM: Debian/Ubuntu or RHEL-family. Ansible + git (installed by `setup.sh`).
- Customer hosts: Debian- or RedHat-family Linux with Python and SSH.
- No Ansible collections needed — `ansible.builtin` only.

---

## Setup

### New control VM (per customer)

Configure the customer's VPN/bastion first, then as a **non-root** user:

```bash
git clone https://github.com/riyanfa/ansible-msp ~/ansible-msp
~/ansible-msp/control/setup.sh clientB https://github.com/riyanfa/ansible-msp
```

Installs ansible+git, creates `~/customers/clientB/`, generates the key, enables
the 30-min auto-pull timer. Safe to re-run.

Then edit `~/customers/clientB/group_vars/all.yml`:

```yaml
mgmt_authorized_keys:
  - "ssh-ed25519 AAAA... ansible-clientB"   # public key setup.sh printed
control_node_ips:
  - "203.0.113.5"
ansible_ssh_private_key_file: "~/.ssh/clientB_ansible"
```

> ⚠️ `control_node_ips` must be what the **host sees**, not what you think the VM's IP is.
> Check first: `ssh <bootstrap-user>@<host> 'echo $SSH_CLIENT'` — first field.
> Wrong value = locked out of every host.

### New host

`chmod 600` the customer's key, add to `~/customers/clientB/onboarding.ini`:

```ini
[new_hosts]
10.0.0.5 ansible_user=root ansible_ssh_private_key_file=~/.ssh/bootstrap/vm1.pem ansible_ssh_common_args='-o IdentitiesOnly=yes'
```

From `~/ansible-msp`:

```bash
ansible-playbook -i ~/customers/clientB/onboarding.ini playbooks/onboard.yml --check --diff
ansible-playbook -i ~/customers/clientB/onboarding.ini playbooks/onboard.yml
ansible-playbook -i ~/customers/clientB/managed.ini    playbooks/verify.yml
```

Host is appended to `managed.ini` automatically. Then delete it from
`onboarding.ini` and `shred -u` the bootstrap key.

![onboarding](diagrams/onboarding_sequence.png)

### Routine

```bash
ansible-playbook -i ~/customers/clientB/managed.ini playbooks/assess.yml   # daily, read-only
ansible-playbook -i ~/customers/clientB/managed.ini playbooks/patch.yml    # maintenance window
```

---

## Playbooks

| Playbook | Inventory | Does | Safe to re-run |
|---|---|---|---|
| `onboard.yml` | onboarding.ini | creates account, key, sudo; promotes host to managed.ini | yes |
| `verify.yml` | managed.ini | proves SSH + sudo work as `svc_ansible` | yes, read-only |
| `assess.yml` | managed.ini | reports pending updates + reboot needed | yes, read-only |
| `patch.yml` | managed.ini | applies updates, batched, optional reboot | yes |

All are idempotent — a second run reports `changed=0`.

`patch.yml` runs with `serial` (default 50% of hosts at a time) and **never reboots
unless told to**.

## Variables

**`~/customers/<name>/group_vars/all.yml`** — applies to both inventories:

| Variable | Default | Notes |
|---|---|---|
| `customer_name` | — | required |
| `mgmt_user` | — | service account name, e.g. `svc_ansible` |
| `mgmt_authorized_keys` | — | list of public keys. Removing one removes it from every host next run. |
| `control_node_ips` | — | the `from=` restriction. Must match what hosts see. |
| `mgmt_sudo_nopasswd` | `true` | `false` → sudo needs a password (`--ask-become-pass`) |
| `ansible_user` | — | set to `"{{ mgmt_user }}"` |
| `ansible_ssh_private_key_file` | — | this customer's key. Wrong path = publickey rejected. |
| `ansible_ssh_common_args` | — | e.g. `-o ProxyJump=user@bastion.customer.com` |

**Run-time (`-e`):**

| Variable | Playbook | Default | Effect |
|---|---|---|---|
| `reboot_if_required` | patch | `false` | reboot hosts that need it |
| `update_batch` | patch | `50%` | `1` = one host at a time |
| `security_only` | patch | `false` | RHEL only; ignored on Debian |
| `expected_mgmt_user` | verify | `mgmt_user` | identity assertion override |

## Verifying it worked

On the host after onboarding:

```bash
id svc_ansible
sudo cat /home/svc_ansible/.ssh/authorized_keys    # from="<IP>",... ssh-ed25519 ...
sudo visudo -c
```

`verify.yml` should report `ok=5 changed=0` and `svc_ansible -> root OK`.

Auto-pull on the control VM: `systemctl --user list-timers repo-sync.timer`

---

## Troubleshooting

Diagnostic order: **host auth log → `authorized_keys` → key the client offers.**

```bash
sudo journalctl -u ssh -S -30min | grep svc_ansible   # Ubuntu/Debian
sudo grep svc_ansible /var/log/secure | tail          # RHEL
```

| Symptom | Cause | Fix |
|---|---|---|
| `Connection closed ... [preauth]` | `from=` rejects the source IP | log shows the real IP — put it in `control_node_ips`, re-run onboard |
| `Permission denied (publickey)` | wrong/missing `ansible_user` or key path in `all.yml`; or host rebuilt | check `all.yml`; `ssh-keygen -y -f <key>` must match `authorized_keys` |
| `Too many authentication failures` | agent offering other customers' keys | add `-o IdentitiesOnly=yes` per host in `onboarding.ini` (never globally) |
| `UNPROTECTED PRIVATE KEY FILE` | key is 0644 | `chmod 600` |
| `Host key verification failed` | ran outside `~/ansible-msp` so `ansible.cfg` didn't load | run from the repo root |
| `Missing: customer_name, ...` | `group_vars/all.yml` not loaded | file must be `all.yml` (not `.example.yml`) next to the inventory |
| `Unable to parse ... inventory source` | file missing or unreadable | check the path in the warning |
| `git pull --ff-only` fails | control VM drifted or history rewritten | `git fetch origin && git reset --hard origin/main` |
| `/boot` full on Debian patch | old kernels | `apt-get autoremove --purge`, re-run |

---

## Operating notes

- **Back up `~/customers/` and `~/.ssh/*_ansible*`** on every control VM. Only copies.
- **Every push to `main` is live everywhere in 30 min.** No staging branch — test with
  `--check --diff` first.
- **Never edit files on a control VM.** Changes go through git; drift = reset the clone.
- **Schedule `verify.yml` daily** — catches rebuilt hosts and broken `from=` restrictions.
- **Key rotation:** add new key to `mgmt_authorized_keys` → onboard → switch
  `ansible_ssh_private_key_file` → verify → remove old key → onboard again.
- **Control VM IP change:** add the new IP to `control_node_ips` and re-run onboard
  **before** decommissioning the old address.
- Repo is public and control VMs run it as root: protect `main`, require 2FA,
  read every external PR.

## Not covered

Windows hosts; patch-compliance history or CVE reporting (Ansible is stateless —
see the results-collector idea if you need dashboards); Linux major-version upgrades.
