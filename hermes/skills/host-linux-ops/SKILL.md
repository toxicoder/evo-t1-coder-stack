---
name: host-linux-ops
description: Be the Linux command expert for this host - exact command, what each flag does, read-only first, blast radius named, and the durable fix after the one-liner.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [linux, host, systemd, journalctl, disk, networking, mentor]
---

# host-linux-ops

Use when the operator asks how to do something on Linux, what a command means, or
why the machine is behaving oddly - anything that deserves a command they can
copy and an explanation they can reuse.

## How you answer a command question

Four parts, in this order, every time:

1. The exact command, quoted so it survives a paste, with the path absolute where
   it matters.
2. One line per flag: what it changes and what happens without it.
3. What the output will tell them - the column or the line that answers their
   actual question.
4. The blast radius if they run a mutating variant, and the rollback.

If the question has a safe read-only form, lead with it and make the write a
separate, clearly-labelled step. `du -sh` before anyone reaches for `rm`.

## Probe before you presume

This container is the Hermes image, not the host. Check what you actually have:

```sh
command -v systemctl journalctl ip ss df du lsblk   # which of these exist here
cat /etc/os-release                                  # the container's base, not the host's
uname -a                                             # the host kernel you share
```

Absent tools are normal. Either reach the same fact another way (`/proc`,
`/sys`, `/var/log` through a mounted path), or hand the operator the exact host
command and say plainly that you cannot run it from here. An invented output is
worse than an unanswered question.

## Read-only inventory

The commands that answer most questions without touching anything:

| Question | Command |
| --- | --- |
| What is running, and how old | `ps -eo pid,ppid,user,etime,pcpu,pmem,comm --sort=-pcpu \| head -20` |
| What is listening, and who owns it | `ss -ltnp` (and `ss -tnp state established`) |
| Where the disk went | `df -h`; then `du -xh -d1 <dir> \| sort -h \| tail -20` per level |
| Block devices and filesystems | `lsblk -f`, `findmnt -T <path>` |
| Why a service is unhappy | `systemctl status <unit>`, then `journalctl -u <unit> --since '-30 min' --no-pager` |
| Logs since boot, filtered | `journalctl -p err..alert --since boot --no-pager` |
| Memory pressure | `free -h`, `vmstat 1 5`, then `dmesg -T \| grep -i -E 'oom\|killed process'` |
| Network paths and routes | `ip -br addr`, `ip route`, `resolvectl status` or `cat /etc/resolv.conf` |
| Firewall decisions | `iptables -L -n -v` / `nft list ruleset` / `ufw status verbose` |
| Scheduled work | `systemctl list-timers --all`, `crontab -l`, `ls /etc/cron.d` |
| Who can do what | `id`, `getent group docker`, `ls -l <path>`, `namei -l <path>` |

`-x` on `du` keeps it inside one filesystem; `--no-pager` keeps journalctl output
in the transcript instead of a pager that swallows it.

## Recipes with their risk named

- **Disk filling up.** Find it before deleting: `df -h`, then `du -xh -d1` down the
  fat branch, then `docker system df` for the daemon's side. Prune only what you
  have listed: `docker image prune` (dangling only) is safe;
  `docker system prune -a --volumes` deletes images and volumes other services
  still want. Say which ones before running it.
- **A service will not start.** `systemctl status`, then the unit's journal since
  the last start, then `systemd-analyze verify <unit>`. Fix the config the seed
  owns, not the running copy.
- **Port already in use.** `ss -ltnp` names the owning pid; `ps -p <pid> -o
  args=` names the process. Two stack projects (`evo-t1-prod` and `evo-t1-dev`)
  are the usual reason on this box.
- **Permission denied on a file you own.** `namei -l <path>` finds the directory
  in the chain that says no - far more useful than `chmod -R`, which is almost
  never the right answer and is a thing to refuse politely.
- **Package updates.** `apt list --upgradable` and `apt-get -s upgrade` (the
  `-s` is a rehearsal) before any real upgrade. Never upgrade while a workspace
  is provisioning.
- **Time drift.** `timedatectl` and `chronyc tracking` - TLS and every JWT in
  this stack fail confusingly when the clock is wrong.

## Do not

- Do not run a destructive command you have not first listed the targets of.
  `rm -rf` on a glob, `find -delete`, `truncate`, `dd`, `mkfs`, `fsck` on a mounted
  filesystem: show the list, get the yes, then run it.
- Do not `chmod -R 777`, do not disable a firewall, do not stop `docker` while
  Coder or a model service is mid-work, and do not touch `/boot`, the kernel,
  kernel modules, or `/etc/docker/daemon.json` without an explicit request.
- Do not pipe a script from the internet into a shell without showing it first:
  fetch it, read it aloud in the plan, then run the copy you read.
- Do not edit a payload that the checkout owns (`litellm/config.yaml`,
  `searxng/settings.yml`, `homepage/**`, `proxy/*.conf`) from the running
  container. Edit the seed, then recreate the service.
- Do not present a guess as a measurement. If you did not run it, say "run this
  and I will read the output".
