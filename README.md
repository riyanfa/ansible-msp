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
# prepare the VM: ansible, git, sshpass, repo clone
git clone https://gitlab.com/riyanalhumaidhi/ansible-msp ~/ansible-msp
~/ansible-msp/control/setup.sh clientb https://gitlab.com/riyanalhumaidhi/ansible-msp
cd ~/ansible-msp

# new customer: generates the key pair, group_vars, inventories
./new-customer.sh clientb "Client B" <this-VM's-egress-IP>

# add hosts — no inventory editing
./add-host.sh clientb 192.168.1.50 root ~/.ssh/their-bootstrap-key.pem
./add-host.sh clientb 10.0.0.1,10.0.0.2,10.0.0.3 root ~/.ssh/their-bootstrap-key.pem
./add-host.sh clientb @hosts.txt root ~/.ssh/their-bootstrap-key.pem   # one host per line
./add-host.sh clientb 192.168.1.51 root          # no key: prompts for password (needs sshpass)

# confirm it worked
ansible-playbook -i customers/clientb/managed.ini playbooks/verify.yml
```

Find the egress IP with `ssh <a-host> 'echo $SSH_CLIENT'` — first field. It goes
into the `from=` restriction on every key, so a wrong value locks you out of the
whole fleet.

Both scripts are idempotent and never overwrite an existing key or `all.yml`.

## Playbooks

| | |
|---|---|
| `onboard.yml` | create the management account, install the restricted key, grant sudo |
| `verify.yml` | prove SSH + sudo work (read-only, schedulable) |
| `assess.yml` | report pending updates and outstanding reboots (read-only) |
| `patch.yml` | apply updates, batched, halts on failure, optional reboot |
| `offboard.yml` | remove our access when a customer leaves |

All idempotent. `ansible.builtin` only — no collections to install.

`assess.yml` also writes a JSON record per host to `~/assess-reports/` on the
control VM — collect those to build patch-compliance reporting.

## Layout

```
new-customer.sh   scaffold a customer: key pair, group_vars, inventories
add-host.sh       onboard one host — no inventory editing
playbooks/        the five playbooks + shared tasks/templates
control/          setup.sh — prepares a control VM
customers/        EXAMPLE files only
docs/             full documentation
```

Real customer data lives in `~/customers/` on the control VM, **outside this
clone** — this repo is public and a `git pull` must never touch it. Override
the location with `MSP_DATA_ROOT`.

## Documentation

**[docs/DOCUMENTATION.md](docs/DOCUMENTATION.md)** — architecture, setup, variables,
verification, troubleshooting.

## Notes

- Control VMs do **not** update themselves. Pull on the VM when you choose, and
  pin a customer to a release with `git checkout <tag>` when they need a specific
  version. Check with `git describe --tags --always`.
- This repo is public and control VMs execute it as root on customer fleets. Protect
  `main`, require 2FA, review every external PR.

## License

MIT
