---
title: Unlock an encrypted host remotely
description: Configure the stack host so a reboot with an encrypted root can be answered from a laptop, and prove the boot image can do it before you reboot.
tags: [operate, luks, disk-encryption, boot, headless, ssh]
---

**What's on this page**

- Why a reboot is the dangerous moment on an encrypted headless box
- The one command that answers "can I unlock this from a laptop"
- What `install` writes, and which file each line belongs to
- The unlock itself, step by step, from the operator's own machine
- What the check catches, and what it deliberately leaves alone

**What this enables**

- Rebooting a server nobody is standing next to
- Catching a config that looks right and boots dead, before the reboot
- Reading the exact ssh command and host key fingerprint to expect

An Ubuntu server with a LUKS root stops in the initramfs on every reboot and
waits for a passphrase. With no keyboard attached, that wait is the outage: the
machine is up, the disks are unreadable, and the only fix is a person at the
console. The distro answer is to move an SSH server and cryptsetup's unlock
prompt into the initramfs, so the passphrase is typed over SSH from anywhere.

`//scripts:luks-unlock` writes that config and then proves the generated
initramfs really contains the unlock path. The proof is the point: every one of
the six settings involved fails by staying silent until the boot that needs it.

## The command that matters

```sh
bazelisk run //scripts:luks-unlock
```

That is `check`, the default verb, and it writes nothing. It answers one
question - if this box rebooted right now, could you decrypt it from a laptop -
and closes with either `ok: this box can be unlocked from a laptop after a
reboot` or `error: do not reboot yet - N blocker(s)`.

Run it before every reboot of an encrypted box, and after any kernel or
`initramfs-tools` update. It exits `1` when something blocks the unlock, so it
fits in front of a maintenance script as a gate.

## What install writes

```sh
bazelisk run //scripts:luks-unlock -- install --pubkey ~/.ssh/id_ed25519.pub
```

`install` installs the two packages, writes the config, regenerates the
initramfs, and then runs the same check over what it produced. Add `--dry-run`
first and every write and command is printed as `would: ...` instead of
executed. Nothing reboots.

| File | Line it writes | Why it matters |
| --- | --- | --- |
| `/etc/cryptsetup-initramfs/conf-hook` | `CRYPTSETUP=y` | Without it the cryptroot scripts never enter the boot image, so there is nothing to type a passphrase into. |
| `/etc/initramfs-tools/conf.d/zz-luks-unlock` | `DROPBEAR=y`, `IP=`, `UMASK=0077`, and `HOOKS=` when a list is in force | One file this CLI owns, named to sort last so it wins over every other drop-in. `IP=` is what gives the boot image an address; `UMASK=0077` keeps the packed key out of unprivileged hands. |
| `/etc/dropbear/initramfs/authorized_keys` | the operator's public key(s) | Password logins are off in the initramfs. No key there means the SSH server refuses everyone, including you. |
| `/etc/dropbear/initramfs/dropbear.conf` | `DROPBEAR_OPTIONS="-p 2222 -s -I 60 -j -k"` | `-s` keeps password logins off, `-I` bounds a session someone walked away from, and the port stays off the installed sshd's so the different host keys do not look like an attack. An existing `DROPBEAR_OPTIONS` is left alone. |
| `/etc/dropbear/initramfs/dropbear_*_host_key` | generated with `dropbearkey` when none exist | dropbear refuses to start with no host key, and the package only creates them at install time. |

The order is deliberate: the hook packs the authorized key at generation time,
so a key written after `update-initramfs` is not in the image. That is why
`install` ends by reading the image back.

## Unlocking from a laptop

1. Pin the identity while the box is still up, so a stranger's key cannot be
   mistaken for it later:

   ```sh
   bazelisk run //scripts:luks-unlock -- fingerprint
   ```

2. Reboot the box.
3. Wait a minute, then connect on the initramfs port. The check prints the
   command; it keeps its own `known_hosts` on purpose:

   ```sh
   ssh -o UserKnownHostsFile=~/.luks/known_hosts \
       -o StrictHostKeyChecking=accept-new -p 2222 root@box.example
   ```

4. Type the passphrase:

   ```sh
   cryptroot-unlock
   ```

The boot continues on its own once the mapping appears - no second reboot. If
the SSH connection is refused, the box is still in the initramfs or before it:
the boot does not proceed past an unmapped root, so waiting is safe and the
console (out-of-band console, IPMI, or the provider's serial console) still
shows where it stopped.

## What the check catches

Every row below is a `check` line you can get instead of an `ok`, and each one
has booted dead in the field.

| Report | Cause | Fix |
| --- | --- | --- |
| `no initramfs address (IP is unset, none, or off)` | nothing ever set `IP=` | `install --ip dhcp`, or `--iface ens3` to pin one NIC, or a raw netboot spec for a static network |
| `HOOKS leaves out net dropbear` | a hand-written `HOOKS=` list that predates the packages | `install` merges the four names it needs into whatever list is in force |
| `the boot image holds no bin/dropbear` | the package was installed after the last `update-initramfs` | re-run `install` so the image is regenerated after the install |
| `no authorized key was packed into the boot image` | the key was written after the image, or in a path the installed hook does not read | re-run `install`; the CLI asks the installed hook which path it reads rather than assuming |
| `the key body holds characters that are not base64` | a pasted key wrapped mid-body | re-paste on one line; `check` names the line |
| `key file /etc/keys/root.key is not covered by KEYFILE_PATTERN` | the crypttab key lives on disk and never reaches the initramfs | add a `KEYFILE_PATTERN` to `conf-hook`, or move that volume to a passphrase |
| `MODULES=dep packs only drivers loaded right now` | the NIC driver is not loaded today, so it will be missing tomorrow | name the driver in `/etc/initramfs-tools/modules`, or go back to `MODULES=most` |
| `the initramfs listens on 2222, the same port the installed sshd uses` | the two daemons share a port with different host keys | pick another `--port`, and keep using the separate `UserKnownHostsFile` |
| `an encrypted /boot needs GRUB to read the initrd` | `/boot` is inside the encrypted volume | verify GRUB can read it before trusting a reboot |

The last one is worth dwelling on: `check` can read every config file and still
be looking at an image GRUB cannot load, so an encrypted `/boot` is reported as
a warning to verify by hand rather than cleared.

## Static networks

A box with no DHCP gets the raw initramfs form, which is passed through
untouched because `initramfs-tools` parses it, not this CLI:

```sh
bazelisk run //scripts:luks-unlock -- install \
  --ip '10.0.0.5::10.0.0.1:255.255.255.0:box:ens3:off' --no-pkgs
```

`--iface ens3` with `--ip dhcp` produces the same pinned-device shape with
DHCP kept. A name the kernel never assigned is a blocker, not a typo you
discover after the reboot: `check` compares it against `/sys/class/net`.

## Two keys, two purposes

The unlock key authorizes a root shell on a machine whose disks are still
sealed, and the initramfs image holding it sits on an unencrypted `/boot`.
Anyone who can read `/boot` can read that public key, so treat it as a
separate credential with its own purpose: a dedicated key whose private half
lives on the laptop you bring to a reboot, not the key you push to every
repository. `UMASK=0077` keeps the image itself out of unprivileged hands, and
the initramfs host keys stay separate from `/etc/ssh` on purpose - they are
generated per boot image, and sharing them would leak which key the sealed
machine answers to.

## What this deliberately does not do

- **Reboot anything.** The reboot is the operator's decision, made after a
  green `check`.
- **Edit `/etc/crypttab` or the LUKS headers.** The volumes are read to decide
  whether the boot can open them. Key slots, passphrases and headers are never
  written, so this CLI cannot be the thing that destroys a key.
- **Enroll a TPM.** `systemd-cryptenroll` is a different design with a
  different failure mode - a firmware update that changes the PCR policy seals
  the box with nobody in the loop - and it belongs in its own change.
- **Add an auto-reboot watchdog.** A box sitting in the initramfs with dropbear
  listening is the recoverable state; rebooting on a timer destroys the
  recovery window and can turn one bad boot into a loop. `-I` bounds the
  session, and the listener stays.

## Where to look next

- [troubleshooting.md](troubleshooting.md) for the symptom-first list once the
  box is back up.
- [public-access.md](public-access.md) for what the box exposes on the network
  after it boots - the initramfs listener is gone by then.
- [operate/index.md](operate/index.md) for the rest of the day-to-day runbooks.
