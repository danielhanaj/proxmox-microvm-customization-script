# pve-vm-provision.sh

Provision a Debian/Ubuntu VM **from the Proxmox host shell** through the QEMU
guest agent. It bundles the steps needed to get a `pve-microvm` guest usable:

1. **Fix networking (udev).** `systemd-networkd` refuses to configure a link
   until `systemd-udevd` has marked it "initialized". Minimal images often ship
   only `libudev1`, so the link stays in `SETUP: pending` forever and the guest
   never gets an IP. The script installs/starts `udev` and triggers it.
2. **Enable root SSH.** Writes `/etc/ssh/sshd_config.d/99-root-login.conf`
   (`PermitRootLogin yes`, `PasswordAuthentication yes`) and optionally sets a
   root password and/or adds an authorized key.
3. **Install `net-config` + repair the boot service.** Injects
   `/usr/local/bin/net-config` (interactive IP/DHCP helper) and rewrites the
   `microvm-static-net.service` unit so a saved static config is re-applied on
   every boot.
4. **Optionally apply a static IP** in one shot.

## Requirements

- Run **on the Proxmox host as root** (`qm` must be in `PATH`).
- The target VM must be **running** and have the **QEMU guest agent** active
  (`qm agent <vmid> ping`). Install `qemu-guest-agent` in the guest if not.
- The udev step may need guest internet access (runs `apt-get install udev`).

## Usage

```
/root/pve-vm-provision.sh <vmid> [options]
```

| Option | Description |
| --- | --- |
| `--root-password PW\|auto\|keep` | Root password. `auto` = generate (default), `keep` = don't change it, only enable login. |
| `--root-pubkey FILE` | Add this public key to root's `authorized_keys`. |
| `--net-config PATH` | Path to the `net-config` helper (default: next to this script, then `/root/net-config`). |
| `--static-ip IP/PREFIX` | Apply a static IPv4 address, e.g. `192.168.0.44/24`. |
| `--gateway IP` | Static gateway (used with `--static-ip`). |
| `--dns IP` | Static DNS (used with `--static-ip`). |
| `--no-udev` | Skip the udev step. |
| `--no-ssh` | Skip the root SSH step. |
| `--no-netconfig` | Do not inject/repair `net-config`. |
| `--reboot` | Reboot the guest when finished. |
| `-h`, `--help` | Show help. |

### Examples

Fully provision a VM, letting it keep its current root password, with a static IP:

```
/root/pve-vm-provision.sh 117 \
  --root-password keep \
  --static-ip 192.168.0.44/24 --gateway 192.168.0.1 --dns 192.168.0.1
```

Generate a random root password and add an SSH key, then reboot:

```
/root/pve-vm-provision.sh 117 --root-password auto \
  --root-pubkey /root/.ssh/id_ed25519.pub --reboot
```

Fix networking/SSH only (no static IP):

```
/root/pve-vm-provision.sh 117 --root-password keep
```

## What happens internally

- The host script builds a small guest payload (`guest.sh`) plus a config file
  and, if used, the `net-config` script.
- These are **base64-encoded and pushed into the guest** with
  `qm guest exec` (the guest agent does not forward stdin, so files are
  transferred inline).
- The payload runs as root inside the guest and prints a `[mvm]` log plus a
  summary (interface, addresses, `PermitRootLogin`, `udevd` state).
- The host decodes the guest's JSON result and returns its exit code.

## Notes / caveats

- Re-running is **idempotent**; safe to run repeatedly on the same VM.
- `--root-password keep` (or `""`) never touches the existing password — use it
  if you have already set one.
- Installing `udev` can rename the interface (predictable names), e.g.
  `eth0` -> `enp0s4`; the network configs match `Type=ether`, so this is fine.
- If the guest has no connectivity, bring the link up and `dhclient` it first;
  otherwise the `udev` install step logs a warning and continues.
- `net-config` is written for `systemd-networkd` guests (Debian/Ubuntu +
  `pve-microvm`).

## Files

| Path | Role |
| --- | --- |
| `/root/pve-vm-provision.sh` | The provisioner (run on the Proxmox host). |
| `/root/net-config` | Interactive network helper injected into the guest as `/usr/local/bin/net-config`. |
