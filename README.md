# ansible-msp

Onboard customer Linux VMs into managed patching, then keep them patched.
Built for an MSP running **one control VM per customer**.

Turns whatever credential a customer hands over (root password, cloud key, `.pem`)
into a standard, isolated management identity — a password-locked `svc_ansible`
account with an SSH key restricted to your control VM's IP — then patches on that
identity.

> This repo holds **workflow only**. Customer inventories, variables and keys live
> on each control VM's disk and are never committed here.

## Quick start

```bash
git clone https://github.com/riyanfa/ansible-msp ~/ansible-msp
~/ansible-msp/control/setup.sh clientB https://github.com/riyanfa/ansible-msp
```

Fill in `~/customers/clientB/group_vars/all.yml`, add a host to `onboarding.ini`, then:

```bash
cd ~/ansible-msp
ansible-playbook -i ~/customers/clientB/onboarding.ini playbooks/onboard.yml
ansible-playbook -i ~/customers/clientB/managed.ini    playbooks/verify.yml
```

## Playbooks

| | |
|---|---|
| `onboard.yml` | create the management account, install the restricted key, grant sudo |
| `verify.yml` | prove SSH + sudo work (read-only, schedulable) |
| `assess.yml` | report pending updates and outstanding reboots (read-only) |
| `patch.yml` | apply updates, batched, optional reboot |

All idempotent. `ansible.builtin` only — no collections to install.

## Layout

```
playbooks/      the four playbooks + shared tasks/templates
control/        setup.sh and the repo-sync systemd timer
customers/      EXAMPLE files only (real data lives on the control VM)
docs/           full documentation
```

## Documentation

**[docs/DOCUMENTATION.md](docs/DOCUMENTATION.md)** — architecture, setup, variables,
verification, troubleshooting.

## Notes

- Control VMs auto-pull `main` every 30 minutes. **A push is live everywhere within
  half an hour** — test with `--check --diff` first.
- This repo is public and control VMs execute it as root on customer fleets. Protect
  `main`, require 2FA, review every external PR.
- Install the commit hook once per clone (git does not sync hooks):
  `cp hooks/pre-commit .git/hooks/ && chmod +x .git/hooks/pre-commit`

## License

MIT
