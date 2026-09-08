# Lab helpers

Drive a throwaway test VM from a workstation. The `system-setup` suites
partition disks, edit `/etc/fstab` and rewrite `~/.bashrc`, so they are only
ever run against a VM you are willing to lose — never a host you care about.

## Setup

Two things, neither of them committed:

```bash
echo 'test-user@10.127.1.123' > tests/lab/target      # or export SS_LAB_HOST
ssh-keygen -t ed25519 -N '' -f tests/lab/lab_key      # then install the .pub
ssh-copy-id -i tests/lab/lab_key.pub test-user@10.127.1.123
```

`target`, `lab_key*` and `known_hosts` are all gitignored — the host is
per-operator and the private key must never be committed.

If you would rather use an existing key or agent, skip `lab_key` entirely:
with no `tests/lab/lab_key` present the helpers fall back to your default
identities.

| Variable | Default | Meaning |
|---|---|---|
| `SS_LAB_HOST` | `tests/lab/target` | `user@host` of the VM |
| `SS_LAB_KEY` | `tests/lab/lab_key` | private key; falls back to the agent if absent |
| `SS_LAB_DIR` | `ss` | directory on the VM, relative to its home |

## Use

```bash
tests/lab/push.sh                                   # copy scripts + suites
tests/lab/ssh.sh 'cd ~/ss && bash tests/run-all.sh' # full regression
tests/lab/ssh.sh 'cd ~/ss && bash tests/test-hdd-expand.sh'
```

`push.sh` copies `system-setup`, `git-utils`, `setup` and `command-shortcuts`
to `~/$SS_LAB_DIR/`, and every `tests/system-setup/` suite to
`~/$SS_LAB_DIR/tests/`. The suites are flat there, so `run-all.sh` looks for
`tests/test-*.sh` on the VM while they live in `tests/system-setup/` here.

## Why these are in the repo

They are driven from non-interactive shells, so `BatchMode=yes` is
load-bearing: without it a password prompt does not fail, it **hangs**.

They previously lived only in a scratch directory and were lost twice —
including mid-task, which cost an hour of rebuilding rather than testing.
Committing the mechanism and gitignoring the credentials keeps the reusable
part and none of the secret part.
