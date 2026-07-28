# Customer patching

One control VM per customer on our premises, holding that customer's VPN/bastion
config, SSH key, and inventory. This **public repo carries only the workflow** —
customer data lives on each control VM's disk and is never committed anywhere.

```
On the control VM:
~/ansible-msp/               this repo, auto-pulled (stable branch)
  playbooks/
    onboard.yml     set up a new host (account + restricted key + sudo)
    verify.yml      prove the control VM can manage the hosts (read-only)
    assess.yml      report pending updates + reboots (read-only, run daily)
    patch.yml       apply updates, ringed, optional reboot
  customers/clientA/         EXAMPLE files only — templates for the real thing
  control/setup.sh           one-command control VM setup

~/customers/<name>/          REAL data — local only, outside the clone
  onboarding.ini    hosts not yet set up — bootstrap creds
  managed.ini       hosts under management
  group_vars/all.yml
```

**Back up `~/customers/` on every control VM.** It is the only copy of what
you manage for that customer — no git history, no remote. A nightly tar to
your admin node is the minimum.

## New customer

Boot a VM, configure its VPN/bastion access to the customer, then:

```bash
git clone -b stable <this repo> ~/ansible-msp
~/ansible-msp/control/setup.sh clientB <this repo's url>
```

`setup.sh` installs ansible, creates `~/customers/clientB/` from the example
files, generates the key, and enables auto-pull. It prints exactly what to
fill into `all.yml` (public key + this VM's egress IP).

## New host

Add to `~/customers/clientB/onboarding.ini` with the creds the customer gave
you (`chmod 600` any key first):

```ini
[new_hosts]
10.0.0.5 ansible_user=root ansible_ssh_private_key_file=~/.ssh/bootstrap/vm1.pem
```

Then from `~/ansible-msp`:

```bash
ansible-playbook -i ~/customers/clientB/onboarding.ini playbooks/onboard.yml --check --diff
ansible-playbook -i ~/customers/clientB/onboarding.ini playbooks/onboard.yml
ansible-playbook -i ~/customers/clientB/managed.ini    playbooks/verify.yml
```

On success the host is appended to `managed.ini` automatically — delete it
from `onboarding.ini` and `shred -u` the bootstrap key.

## Patching

```bash
ansible-playbook -i ~/customers/clientB/managed.ini playbooks/assess.yml   # daily, safe
ansible-playbook -i ~/customers/clientB/managed.ini playbooks/patch.yml    # in their window
```

patch.yml options: `-e reboot_if_required=true`, `-e update_batch=1` (serial),
`-e security_only=true` (RHEL only).

## Workflow updates → control VMs

Control VMs auto-pull the **stable** branch every 30 min (`control/repo-sync.*`).
Changes flow through a staging gate:

```
push → main → test on ONE control VM → git push origin main:stable → all VMs
```

⚠️ **This repo is public and control VMs execute what they pull as root on
customer fleets.** That makes repo security operational security:

- Protect `stable` and `main`: no force pushes, no direct pushes from others.
- 2FA on every account with write access. Never merge external PRs into
  `stable` without reading every line of the diff.
- Control VMs pull anonymously (public repo needs no key) and never push.
- `--ff-only` in the sync means rewritten history is refused, not applied.
- Never edit anything on a control VM — a failing sync timer means drift;
  reset the clone, don't fix it.

## Rules

- Connection quirks (VPN routes, ProxyJump, DNS) live in the control VM or in
  that customer's `group_vars/all.yml` — never in playbooks. The repo stays
  identical on every control VM.
- `authorized_keys` is fully managed: removing a key from `mgmt_authorized_keys`
  removes it from every host on the next run.
- The key is IP-locked (`from=`). If a control VM's IP changes, re-run onboard
  playbook key task before anything else.
- Commit hook (per clone): `cp hooks/pre-commit .git/hooks/ && chmod +x .git/hooks/pre-commit`
