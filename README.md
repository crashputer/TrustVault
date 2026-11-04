# TrustVault

This project uses two Debian-based Linux machines at different sites. Each one serves a shared folder to its local network to be used as a standard NAS and sends an encrypted backup of that folder to the other over ZeroTier. Neither owner can read the other's backups, and neither machine can delete or alter backups it has already sent.

**Status:** This script is an early draft. Test it on two VMs or spare machines before using it on real data.

## Prerequisites

### A Debian-based Linux installation

> This script is designed to run on a Debian-based Linux installation that uses systemd (Debian, Ubuntu, Mint, etc). Use a non-root user account with sudo. This user account will also be the user of the smb share created during installation.

### Internet Access

> Internet access is required during installation. TrustVault downloads restic and rest-server from GitHub and checks their SHA256 checksums.

### ZeroTier

> **TrustVault cannot create a ZeroTier account or network for you. One of the two people must do this first, outside TrustVault.**
>
> 1. Create an account at <https://my.zerotier.com>. ZeroTier offers a free plan; check their site for current terms.
> 2. Click **Create A Network** and copy its 16-character **Network ID**.
> 3. Send that Network ID to the other person. Both machines join the same network.
>
> Later, after `apply` has run on each machine, the network owner returns to the network's page and ticks **Auth** next to each machine's node ID under **Members**. Backups cannot start until both machines are authorized.

TrustVault installs the ZeroTier software itself if it's missing, using ZeroTier's official installer (`curl https://install.zerotier.com | bash`). If you'd rather install it another way, do that first and TrustVault will use the existing installation.

## How it works

On each machine, three things run.

The **network share** is a Samba share defined in its own file, `/etc/samba/trustvault.conf`, and pulled in with a single `include` line appended to `smb.conf`. Existing shares and settings are not touched.

The **sender** is restic, run by a systemd timer as an unprivileged `trustvault` user. It reads the share using the `CAP_DAC_READ_SEARCH` capability rather than running as root. Backups are encrypted on the local machine before being transmitted.

The **receiver** is rest-server, run as a separate `trustvault-recv` user. It listens only on the ZeroTier address and runs with `--append-only` and `--private-repos`, so the peer can add new snapshots but cannot delete or overwrite old ones, and can only see its own repository.

| What | Where |
|---|---|
| Configuration | `/etc/trustvault/trustvault.conf` |
| Keys and passwords | `/etc/trustvault/secrets/`, `/etc/trustvault/htpasswd` |
| Binaries (pinned restic and rest-server, and the script itself) | `/opt/trustvault/bin/` (command symlinked as `/usr/local/sbin/trustvault`) |
| State | `/var/lib/trustvault/` |
| systemd units | `trustvault-receiver.service`, `trustvault-backup.timer`, `trustvault-check.timer` |
| Install log | `/var/log/trustvault.log` |

Service logs go to the journal: `journalctl -u trustvault-backup`.

## Setup

Do steps 1–5 on **both** machines.

1. `wget https://raw.githubusercontent.com/crashputer/TrustVault/refs/heads/main/trustvault.sh`
2. `chmod +x trustvault.sh`
3. `sudo ./trustvault.sh configure` asks for the share, the ZeroTier Network ID, ports and schedule. It generates the encryption key and shows a **recovery sheet**. Store the sheet off the machine (print it or put it in a password manager), then delete `/root/trustvault-RECOVERY.txt`.
4. `sudo ./trustvault.sh apply` installs and configures everything and prints how to connect to the share. It offers to set a Samba password for any share user who doesn't have one. It's safe to re-run, and `--dry-run` shows what it would do without changing anything.
5. The ZeroTier network owner authorizes this machine's node ID (printed by `apply`) at my.zerotier.com. Then run `sudo trustvault apply` again so it picks up the ZeroTier interface and adds the firewall rules.

Then pair the two machines:

6. On each machine, run `sudo trustvault pairing-info` and send the output to the other person **privately**, for example in person, by phone, or through a password manager.
7. On each machine, run `sudo trustvault set-peer` and enter what the other person sent. It offers to run `apply`, which initializes the encrypted repository on the peer and enables the backup timer.

## Connecting to the share

At the end of every `apply`, and at any time with `sudo trustvault share-info`, TrustVault prints the four things a person needs to connect from another computer on the same local network:

| What you need | Where it comes from |
|---|---|
| **Computer name** | This machine's hostname, for example `mintbox`. |
| **IP address** | This machine's address on the local network, for example `192.168.1.20`. ZeroTier, Docker and VM interfaces are left out. |
| **Username** | A Linux user name listed in `SHARE_USERS`. Some systems ask for it as `mintbox\username`. |
| **Password** | That user's **Samba password**. This is separate from their Linux login password, unless you deliberately set them the same. |

Set or change a Samba password with `sudo trustvault share-password USER`.

With a share named `nas` on a computer called `mintbox` at `192.168.1.20`, these are the addresses to use:

| From | Address |
|---|---|
| Windows (File Explorer address bar, or **Map network drive**) | `\\mintbox\nas` or `\\192.168.1.20\nas` |
| macOS (Finder → Go → Connect to Server) | `smb://mintbox.local/nas` or `smb://192.168.1.20/nas` |
| Linux (file manager address bar) | `smb://mintbox.local/nas` or `smb://192.168.1.20/nas` |

If the computer name doesn't work, use the IP address. Home routers usually hand out addresses that can change, so reserve a fixed IP for the TrustVault machine in your router's DHCP settings. Otherwise the address in your saved connections may stop working.

To add another user later: create the Linux user, add the name to `SHARE_USERS` in `/etc/trustvault/trustvault.conf`, then run `sudo trustvault apply` and `sudo trustvault share-password NEWUSER`.

## Day to day

```
sudo trustvault status        # ZeroTier, services, timers, disk space, latest snapshot
sudo trustvault share-info    # how to connect to the share
sudo trustvault backup-now
sudo trustvault restic snapshots
sudo trustvault restic restore latest --target /tmp/restore --include "/srv/nas/Documents"
```

A weekly timer runs `restic check --read-data-subset=5%`, so a random 5% of the stored data is downloaded and verified each week. If you set `HEALTHCHECK_URL` (for example a healthchecks.io check), each backup pings it at start, on success and on failure, so you're alerted when backups stop.

## Pruning old snapshots

Because the receiver is append-only, the sender cannot delete its own old snapshots, so the repository grows over time. Pruning therefore needs the **receiver's** consent:

1. The machine *holding* the backups runs `sudo trustvault maintenance-window 60`. This starts a second, non-append-only receiver on the next port up for 60 minutes.
2. The machine *owning* the backups runs `sudo trustvault prune`, which keeps 7 daily, 4 weekly and 12 monthly snapshots (configurable in the config file).

The window closes automatically when the time is up. During the window the peer could delete its whole repository, so only open one when asked.

## Restoring after losing a machine

You need:

* the recovery sheet,
* a login on the peer (the peer can issue a new password if yours is lost), and
* any Linux computer with restic installed that has joined the ZeroTier network.

The sheet contains the exact commands to run. For a full rebuild, the simplest route is:

1. Reinstall TrustVault and run `configure`.
2. Replace `/etc/trustvault/secrets/repo-password` with the password from the sheet.
3. Pair with the peer again, then restore.

## Uninstall

`sudo trustvault uninstall` removes the services, binaries, firewall rules and Samba share definition. Adding `--purge` also removes the configuration, the **keys** and the system users.

Your shared files and the peer's backups are never deleted automatically.

## Known limitations and next steps
* **If this is running in a Proxmox LXC, after the container is created, run the following command on the server's console with the container stopped: `ptc set <CTID> -dev0 /dev/net/run`
* **Plain HTTP over ZeroTier.** Traffic is encrypted by ZeroTier, and the backup data itself is encrypted by restic, but rest-server is not set up with TLS.
* **The share is not limited to the local network.** Samba listens on all interfaces, including ZeroTier. A password is still required to connect, but if no firewall is active, the peer could attempt to reach your share over ZeroTier. Restricting Samba to local subnets is a planned improvement.
* **`apply` must be re-run after editing the config file.** Changing `RECV_PORT` while firewall rules exist leaves the old rules behind; run `uninstall`, then `apply` in that case.
* **Pairing is manual.** You exchange the details by hand; there is no pairing code yet.
* **Monitoring is limited to the healthcheck ping.** There are no disk-space or SMART alerts yet.
* **Pinned versions need manual updates.** restic and rest-server are pinned in the variables at the top of the script; update them deliberately and re-run `apply`.
