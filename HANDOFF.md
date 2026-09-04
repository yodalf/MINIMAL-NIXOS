# Handoff: minimal NixOS server on Vultr, running headscale

Date: 2026-09-04 (first written 2026-09-02). State at handoff: one server
installed and deployed to, generation 12 (Quad9 DNS for clients), NixOS 26.11pre from nixos-unstable;
it runs headscale 0.29.3 at https://hs.realo.ca with three nodes connected
(branch `headscale`, see the section at the end). It upgrades itself nightly
and collects garbage daily, and snapshots the headscale state daily (pull with `build.sh backup`).

## What exists

| Thing | Where | Notes |
|-------|-------|-------|
| Config repo | `~/Work/MINIMAL-NIXOS` on the Mac, mirror at https://github.com/yodalf/MINIMAL-NIXOS (public) | `main` = generic server; `headscale` branch = what is deployed. Both pushed |
| Installer ISO | GitHub release `v0.1`, also `out/` locally and `result/` on the dev VM | 497 MB, x86_64, hybrid BIOS+UEFI, installs offline |
| Vultr instance | label `headscale` (was `minimal-server`), id `78bb9d0c-b470-4709-8987-ae2be76d2db2`, **104.238.132.193**, plan `vc2-1c-0.5gb` (1 vCPU, 512 MB, 10 GB), region `ewr` | $3.50/month, legacy BIOS boot, OS hostname `headscale` (Vultr's own hostname field still says `server`, it is fixed at creation) |
| Vultr firewall | group `headscale`, id `24b1ef7d-540d-4823-a6ff-f6c7b262775f`, attached to the instance 2026-09-03 | IPv4 inbound only (the instance has no IPv6): tcp 22, 80, 443 and ICMP from anywhere, everything else dropped at Vultr's edge. gRPC 50443 stays closed. Mirrors `networking.firewall` on the box; change both when adding a port. Managed via `/v2/firewalls/<id>/rules` with the API key |
| DNS | `hs.realo.ca` A -> 104.238.132.193 | Dyn Standard DNS (account.dyn.com, Zone Level Services > realo.ca). Vultr IPs are static for the instance's lifetime, no DDNS needed |
| Dev/build VM | `realo@192.168.2.199` (NixOS aarch64, hostname realix) | Builds everything under x86_64 binfmt emulation. Work dir `/home/realo/Data/Work/MINIMAL-SERVER`. Its own NixOS config lives in the realix-iso repo (`/home/realo/Data/Work/realix-iso`, GitHub yodalf/realix-iso) and is updated with `sudo /etc/nixos/update.sh`. Key login is refused: `build.sh` needs `VM_PASS`. Also a tailnet node, `realix.ts.realo.ca` |
| Vultr API key | `~/.config/vultr/api_key` on the Mac (mode 600) | Access-controlled to the home IP 70.31.223.159 in the Vultr panel |
| Backups | `/var/backups/headscale/*.tar.gz` on the server (daily, 30 kept); copies in `~/Backups/headscale/headscale/` on the Mac | Pulled by hand with `SERVER=root@104.238.132.193 ./build.sh backup`; last pull 2026-09-03. Restore steps in the headscale section |

Installed closure: ~976 MiB (908 before headscale, 966 on 26.05). Idle memory: ~135 MB used of 460 MB. Disk: 4.8 GB of 9.5 used (2 GB of it the swap file; drops once the 26.05 generations are collected on 2026-09-05).

## How it fits together

- `modules/headscale.nix` is this machine's role (see the headscale section below). `modules/server.nix` is the generic box: virtio-only initrd, hybrid GRUB on `/dev/vda` with an ESP at `/boot`, systemd-networkd + DHCP, sshd (key only), zram swap, no firmware, no docs, no nixpkgs source in the closure, no Python (`nixos-rebuild` disabled, tiny `rebuild` script instead), no LVM, no guest agent.
- `modules/installer.nix` is the live ISO: `iso-image.nix` + `profiles/minimal.nix` only. It embeds the prebuilt server closure and a `vultr-install` script that partitions the disk (1 M BIOS boot, 256 M ESP, rest ext4 labelled `nixos`), runs `nixos-install --system <closure>` and copies the repo to `/etc/nixos`. No network needed.
- `flake.nix` follows nixpkgs `nixos-unstable` (switched from `nixos-26.05` on 2026-09-03; `system.stateVersion` stays 26.05). `packages.x86_64-linux.{iso,server,src}`. `src` is an explicit file set so nothing stray in the directory ends up in the ISO.
- `build.sh` rsyncs the repo to the VM and runs everything there: `eval`, `server`, `iso`, `test`, `deploy`. All evaluation and building happens on the dev VM; the server can rebuild itself since 2026-09-03 but that path is for the nightly timer and emergencies (owner's preference: the hard work stays on the VM).

## Day-to-day

Change the config and deploy:

```sh
vim modules/server.nix
scp root@104.238.132.193:/etc/nixos/flake.lock .    # take the server's (nightly-updated) lock, see below
SERVER=root@104.238.132.193 VM_PASS=<vm password> ./build.sh deploy         # switch now
SERVER=root@104.238.132.193 VM_PASS=<vm password> ./build.sh deploy boot    # next reboot
git commit -am "..." && git push
```

Under the hood that is `nixos-rebuild switch --flake .#server --target-host root@<ip>` on the dev VM, then a tar copy of the file set (flake, modules, build.sh, README, test) to `/etc/nixos` on the server. Without `VM_PASS`, key-based ssh to the VM is used.

Fallback only (not the normal flow): since 2026-09-03 the server can rebuild itself (2 GB swap file, see gotchas). Copy the files and run `rebuild` there:

```sh
tar cf - flake.nix flake.lock modules build.sh README.md test | ssh root@104.238.132.193 'rm -rf /etc/nixos && mkdir /etc/nixos && tar xf - -C /etc/nixos'
ssh root@104.238.132.193 rebuild dry-activate    # ~2.5 min cold, ~40 s warm; then `rebuild` (switch) or `rebuild boot`
```

Automatic upgrades and store maintenance (all in `server.nix`, first deployed 2026-09-03 as generation 5; gc made daily and retention cut to 2 days later that day; the backup timer came with generation 10):

| Unit | When | What |
|------|------|------|
| `nixos-upgrade.timer` | daily 04:40 UTC + up to 30 min jitter, persistent | `nix flake update nixpkgs --flake /etc/nixos`, `rebuild boot`; reboots one minute later if kernel/modules/initrd changed, else live `switch-to-configuration switch`. `OnSuccess` starts `nix-gc.service` |
| `nix-gc.timer` | daily 00:00 UTC + up to 30 min jitter, persistent | `nix-collect-garbage --delete-older-than 2d` (tested by hand 2026-09-03: 651 MB freed, 18 s; generations under 2 days are kept) |
| `nix-optimise.timer` | weekly | `nix-store --optimise` (on top of `auto-optimise-store`) |
| `headscale-backup.timer` | daily 03:00 UTC + up to 10 min jitter | snapshot of `/var/lib/headscale` to `/var/backups/headscale`, 30 kept (headscale.nix; see the headscale section) |

It is a hand-written unit, not `system.autoUpgrade`: that module hardcodes `nixos-rebuild` (127 MB of Python). The first manual run (`systemctl start nixos-upgrade`) found nixpkgs unchanged but still rebooted, correctly: the box had been live-switched since the ISO install and had never booted the headscale generation's initrd. Check on it with `journalctl -u nixos-upgrade` and `systemctl list-timers`. The server's `/etc/nixos/flake.lock` moves ahead of the repo's every night, hence the `scp` above before deploying.

Rebuild the ISO (only needed for installing new machines; ~15 min under emulation):

```sh
VM_PASS=... ./build.sh iso          # -> out/*.iso
gh release create v0.2 out/*.iso    # or upload to the existing release
```

Test an ISO without touching Vultr, on the dev VM in the repo dir:

```sh
test/qemu-manual.sh install   # boot ISO on a qcow2 disk, run vultr-install, poweroff
test/qemu-manual.sh boot      # boot the installed disk; ssh -p 2222 realo@192.168.2.199
UEFI=1 test/qemu-manual.sh …  # same with OVMF firmware
```

`test/qemu-boot-test.sh` is the scripted (expect) version. It has never completed a full run; the manual script is proven.

Install a new Vultr server from the ISO, fully from the Mac (this is what was done today):

1. Register the ISO: Vultr needs a direct URL and does not follow redirects. Get the final URL with `curl -sI <github release asset url> | grep -i location` and POST it to `/v2/iso`. It downloads in under a minute. The account allows only 2 ISOs.
2. `POST /v2/instances` with `region`, `plan`, `iso_id`, `label`, and the two `sshkey_id`s (Mac ed25519 and the VM's "LOCK" key).
3. When `main_ip` is assigned and the ISO has booted, `ssh root@<ip>` (the installer runs sshd with the same keys) and run `echo YES | vultr-install /dev/vda`.
4. `POST /v2/instances/<id>/iso/detach` (Vultr reboots the instance), wait for hostname `server` on ssh, then `build.sh deploy` once.

Rescue: attach the ISO to the instance again and boot it. It auto-logs in as root on the console and accepts ssh with the usual keys; mount `/dev/vda3` at `/mnt` and `/dev/vda2` at `/mnt/boot`.

## Access

- `ssh root@104.238.132.193` or `ssh realo@…` with the Mac ed25519 key or the dev VM's RSA key. `realo` is in `wheel`, sudo needs no password.
- There is no password on any account. The Vultr VNC console cannot log in to the installed system; use the ISO as a rescue disk instead. To allow console login set `users.users.realo.hashedPassword` (output of `openssl passwd -6`) and deploy.
- Host keys: the installer and the installed system have different host keys for the same IP. The ssh calls in the scripts use `StrictHostKeyChecking=accept-new`; clear the entry from `~/.ssh/known_hosts` if you reinstall.

## Gotchas learned

- Evaluating this config needs ~750 MB (measured 2026-09-03 with `systemd-run --wait`: 230 MB resident, 550 MB swap peak). On zram alone it cannot fit; with the 2 GB `/swapfile` (`swapDevices` in server.nix, created by NixOS at boot, priority below zram) `rebuild` takes 2 min 16 s cold including the nixpkgs download, ~40 s warm, ~16 s with a warm eval cache. Headscale is not disturbed.
- `/etc/nixos` on the server was found stale on 2026-09-03: it still had the placeholder headscale module (loopback :8080) while the running system was the TLS one; the last two deploys of 2026-09-02 had not refreshed it. A local `rebuild` from it would have dropped port 443. The deploy refresh is now a plain tar copy instead of a `nix build` of `packages.src`. If in doubt: `diff -r` the repo against `/etc/nixos` before running `rebuild` on the box.
- The `rebuild` script originally had only nix on its PATH and failed under systemd (`id: command not found`); it now includes coreutils and calls `/run/wrappers/bin/sudo`.
- Anything in the repo directory on the dev VM ends up inside the ISO if it is in the `src` file set; a disk image once added 800 MB to the ISO. `build.sh` now excludes `*.log`/`*.qcow2` and the file set is explicit, but keep junk out of `/home/realo/Data/Work/MINIMAL-SERVER`.
- `nixos-rebuild build` in that directory overwrites the `result` symlink that `build.sh iso` also uses. Re-run `nix build .#packages.x86_64-linux.iso --out-link result` (instant when cached) to restore it.
- The dev VM's login shell is fish. Remote one-liners must be wrapped in `bash -c` or piped to `bash -s`. sshpass needs `-o PubkeyAuthentication=no -o PreferredAuthentications=password` or the Mac's agent keys trip "too many authentication failures".
- Vultr custom ISOs boot in legacy BIOS mode on this plan (the installed GRUB covers both modes anyway). The disk is virtio-blk (`/dev/vda`), network is `ens3` with DHCP.
- The kernel console order is `console=tty0 console=ttyS0`: the serial port is the primary console (systemd status, emergency shell); the VNC console shows the kernel log and a getty. `boot.consoleLogLevel = 7`.
- GitHub release URLs fail on Vultr (redirect). A signed CDN URL expires after ~1 hour, so register it right after fetching it.

## Loose ends

- A stopped, unlabeled `vc2-1c-0.5gb` instance from 2017 (45.77.78.141, id `b3506f78-…`) is still in the account and still billed $3.50/month. Not touched. Destroy it if it is not needed.
- The ISO in Vultr's panel is named after the CDN blob id (`501cb7f9-…`) rather than the `.iso` filename. Harmless.
- The dev VM's nix store holds an unreferenced ~760 MB source copy that included the disk image; its daily GC (7 days) will remove it.
- Firewall is on with 22, 80 and 443 open, on the box (nftables) and at Vultr (firewall group `headscale`, see What exists). Nightly upgrades, daily gc and weekly optimise are in place (see Day-to-day); no monitoring, so a failed `nixos-upgrade.service` or `headscale-backup.service` goes unnoticed unless you look at the journal. `/var/lib/headscale` is snapshotted daily on the box (see the headscale section); the off-box copy depends on someone running `build.sh backup` on the Mac.
- Disk: 4.3 GB used of 9.5 (swap file, nixpkgs source, the 26.05 and 26.11 closures side by side); each nightly upgrade that changes nixpkgs adds a generation until gc removes it after 2 days. Generations 1 to 7 (the 26.05 ones) go at the 2026-09-05 run.
- The QEMU expect test (`test/qemu-boot-test.sh`) prompt patterns were fixed but the script has not been run to completion since; it also now requires `CONSOLE_PASSWORD` because the server has no password.
- Possible further trimming, not done: a custom kernel config (the 145 MB module tree is the single largest item) and dropping git/vim (~95 MB).

## Headscale (branch `headscale`, deployed 2026-09-02)

`modules/headscale.nix`, imported by the `server` config in `flake.nix`,
enables `services.headscale` (headscale 0.29.3 from nixos-unstable since 2026-09-03; 0.28.0 under 26.05 before, the SQLite db migrated on first start with no manual step) and sets
`networking.hostName = "headscale"` (server.nix's hostname is now a
`mkDefault`). Settings that matter:

| Setting | Value | Why |
|---------|-------|-----|
| `server_url` | `https://hs.realo.ca` | public control-server address (`fqdn` at the top of the module) |
| listener | `0.0.0.0:443` | module grants `CAP_NET_BIND_SERVICE` for ports < 1024 |
| TLS | `tls_letsencrypt_hostname` + HTTP-01 on port 80 | headscale's built-in ACME client; cert cached in `/var/lib/headscale/.cache`, renews itself. Current cert expires 2026-12-01 |
| `dns.base_domain` | `ts.realo.ca` (`baseDomain` in the module) | MagicDNS suffix, tailnet-internal only, no public record. Must differ from and not be a parent of hs.realo.ca |
| `dns.nameservers.global` | Quad9 secured: 9.9.9.9, 149.112.112.112, 2620:fe::fe, 2620:fe::9 with `override_local_dns` (since 2026-09-04; Cloudflare before) | clients use these while connected. Plain addresses: Tailscale knows them and upgrades to DoH (dns.quad9.net) on the client, no URL needed. Check with `tailscale dns status` on a node |
| DERP | Tailscale's public relay map, auto-updated | no embedded DERP on 512 MB |
| database | SQLite, `/var/lib/headscale/db.sqlite` | |
| `unix_socket_permission` | `"0770"` | without it headscale chmods its CLI socket to 0700 and only root can use the CLI |
| gRPC | listens on :50443 by default | not opened in the firewall, so unreachable from outside |

`realo` is in the `headscale` group, so the CLI works without sudo. Deploy
is unchanged: `SERVER=root@104.238.132.193 VM_PASS=... ./build.sh deploy`.

State on the server: one user `realo` (id 1) and three nodes, all under it:

| Node | Device | Tailnet IP | Client config |
|------|--------|------------|---------------|
| `kerberos` | iPhone (iOS Tailscale app; reports hostname `localhost`, renamed) | 100.64.0.1 | iOS Settings app, see below |
| `chaos` | the Mac | 100.64.0.2 | Tailscale for macOS, `tailscale login --login-server` |
| `realix` | the dev VM | 100.64.0.3 | `services.tailscale` in realix-iso commit da5480a: `openFirewall = true`, `tailscale0` is a trusted firewall interface |

Verified: Mac -> `tailscale ping kerberos.ts.realo.ca` works; the VM is
reachable from the phone and the Mac over the tailnet.

Adding a device (a headscale "user" is a namespace for nodes, not a login;
all your own machines go under `realo`):

```sh
# on the client
tailscale login --login-server https://hs.realo.ca        # prints a URL with mkey:...
# on the server, as realo
headscale nodes register --user realo --key mkey:...
headscale nodes list
headscale nodes rename --identifier <id> <name>
# or, for CLI clients, skip the browser step with a preauth key:
headscale preauthkeys create --user 1 --reusable --expiration 24h
tailscale up --login-server https://hs.realo.ca --authkey <key>
```

iOS: the alternate server is set in the iPhone's Settings app (Settings >
Tailscale > Alternate coordination server URL), not inside the Tailscale app,
and the app must be force-quit and reopened to pick it up. Then Log in opens
a hs.realo.ca page showing the `headscale nodes register` command.

Gotchas found:

- Let's Encrypt allows 5 failed validations per hostname per hour: make sure
  the A record resolves before deploying a config that requests a cert.
- The NixOS module writes no `unix_socket_permission`, hence the 0700 socket
  (fixed in the module, see table).
- Activation does not change the running hostname; `hostnamectl` showed a
  transient `server` until `hostname headscale` was run by hand. A reboot
  fixes it too.
- The server has no rsync; use `tar | ssh` if you ever need to copy a tree
  there by hand. `build.sh deploy` refreshes `/etc/nixos` on its own.

`headscale` is a permanent, independent branch: it is never merged into
`main`, which stays the generic server. Rebase or cherry-pick generic fixes
from `main` onto it as needed.

What `/var/lib/headscale` holds (372 KB, owner `headscale`): `db.sqlite`
(+ `-wal`/`-shm`; users, nodes, keys, IPs), `noise_private.key` (the server
identity every client pinned; losing it or the db means re-registering all
nodes) and `.cache/` (Let's Encrypt account key and the current cert;
harmless to lose, headscale re-requests). Back up the db with
`sqlite3 db.sqlite ".backup <file>"` or with headscale stopped, never by
copying the raw file while it runs.

Backups (since 2026-09-03): `headscale-backup.timer` (03:00 UTC daily, up to
10 min jitter, persistent) writes `/var/backups/headscale/headscale-<utc
stamp>.tar.gz` (~9 KB; `latest.tar.gz` points at the newest, 30 kept). Each
holds a consistent `db.sqlite` made with sqlite's online backup API,
`noise_private.key` and `.cache/` (ACME). The server cannot reach the Mac or
the dev VM, so the off-box copy is a pull from the Mac:

```sh
SERVER=root@104.238.132.193 ./build.sh backup     # -> ~/Backups/headscale/headscale/*.tar.gz (BACKUP_DIR overrides)
```

Run it now and then (a launchd job on the Mac would automate it; not set up).
Verified 2026-09-03: `pragma integrity_check` ok on the snapshot db, 3 nodes.
Restore, on the server:

```sh
systemctl stop headscale
rm -rf /var/lib/headscale/* /var/lib/headscale/.cache
tar -C /var/lib -xzf /var/backups/headscale/<snapshot>.tar.gz   # or one copied back from the Mac
chown -R headscale:headscale /var/lib/headscale
systemctl start headscale
```

Not done: an ACL policy (all nodes of `realo` can reach each other, which is
the default).
