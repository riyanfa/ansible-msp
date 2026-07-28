# Customer patching

One control VM per customer on our premises, holding that customer's VPN/bastion
config and SSH key. All control VMs run this same repo; each only touches its
own `customers/<name>/` folder.

```
playbooks/
  onboard.yml     set up a new host (account + restricted key + sudo)
  verify.yml      prove the control VM can manage the hosts (read-only)
  assess.yml      report pending updates + reboots (read-only, run daily)
  patch.yml       apply updates, ringed, optional reboot
customers/<name>/
  onboarding.ini  hosts not yet set up — bootstrap creds (gitignored)
  managed.ini     hosts under management — no creds
  group_vars/
    all.yml       customer settings + connection specifics (committed)
```

## New customer

```bash
ssh-keygen -t ed25519 -C "ansible-clientB" -f ~/.ssh/clientB_ansible   # on their control VM

mkdir -p customers/clientB/group_vars
cp customers/clientA/group_vars/all.example.yml customers/clientB/group_vars/all.yml  # edit
printf '[managed]\n' > customers/clientB/managed.ini
git add customers/clientB && git commit && git push
```

`all.yml` needs: the public key, the control VM's IP as seen by customer hosts
(`ssh <host> 'echo $SSH_CLIENT'`), and any connection specifics (ProxyJump etc).
The private key stays on the control VM only.

## New host

Add to `customers/clientB/onboarding.ini` with the creds the customer gave you
(`chmod 600` any key first):

```ini
[new_hosts]
10.0.0.5 ansible_user=root ansible_ssh_private_key_file=~/.ssh/bootstrap/vm1.pem
```

From that customer's control VM:

```bash
ansible-playbook -i customers/clientB/onboarding.ini playbooks/onboard.yml --check --diff
ansible-playbook -i customers/clientB/onboarding.ini playbooks/onboard.yml
ansible-playbook -i customers/clientB/managed.ini    playbooks/verify.yml
```

On success the host is appended to `managed.ini` — commit and push it, delete
the host from `onboarding.ini`, and `shred -u` the bootstrap key.

## Patching

```bash
ansible-playbook -i customers/clientB/managed.ini playbooks/assess.yml   # daily, safe
ansible-playbook -i customers/clientB/managed.ini playbooks/patch.yml    # in their window
```

patch.yml options: `-e reboot_if_required=true`, `-e update_batch=1` (serial),
`-e security_only=true` (RHEL only).

## Central repo → control VMs

This repo is the single source of config for every control VM. Changes flow
one way, through a staging gate:

```
you push → main → test on ONE control VM → promote → stable → all control VMs
```

Control VMs track the **stable** branch and auto-pull every 30 min via a
systemd timer (`control/repo-sync.*` — install instructions in the unit file).
`--ff-only` means a rewritten history is refused, never silently applied.

Promote after testing on one customer:

```bash
git push origin main:stable
```

Rules that make this safe:

- **Never edit anything on a control VM.** All changes via git. A failing
  sync timer means a VM has drifted — reset it, don't fix it.
- Control VMs clone with a **read-only deploy key**. They can pull, never push.
- A bad change on `main` hits one test customer. `stable` is what can hurt
  everyone — promote deliberately.

## Rules

- Connection quirks (VPN routes, ProxyJump, DNS) live in the control VM or in
  that customer's `group_vars/all.yml` — never in playbooks. The repo stays
  identical on every control VM.
- `authorized_keys` is fully managed: removing a key from `mgmt_authorized_keys`
  removes it from every host on the next run.
- The key is IP-locked (`from=`). If a control VM's IP changes, re-run onboard
  playbook key task before anything else.
- Commit hook (per clone): `cp hooks/pre-commit .git/hooks/ && chmod +x .git/hooks/pre-commit`
