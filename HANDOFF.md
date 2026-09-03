# Handoff: minimal NixOS server on Vultr, running headscale

Date: 2026-09-02. State at handoff: one server installed and deployed to; it
runs headscale at https://hs.realo.ca with three nodes connected (branch
`headscale`, see the section at the end).

## What exists

| Thing | Where | Notes |
|-------|-------|-------|
| Config repo | `~/Work/MINIMAL-NIXOS` on the Mac, mirror at https://github.com/yodalf/MINIMAL-NIXOS (public) | `main` = generic server; `headscale` branch = what is deployed. Both pushed |
| Installer ISO | GitHub release `v0.1`, also `out/` locally and `result/` on the dev VM | 497 MB, x86_64, hybrid BIOS+UEFI, installs offline |
| Vultr instance | label `headscale` (was `minimal-server`), id `78bb9d0c-b470-4709-8987-ae2be76d2db2`, **104.238.132.193**, plan `vc2-1c-0.5gb` (1 vCPU, 512 MB, 10 GB), region `ewr` | $3.50/month, legacy BIOS boot, OS hostname `headscale` (Vultr's own hostname field still says `server`, it is fixed at creation) |
| DNS | `hs.realo.ca` A -> 104.238.132.193 | Dyn Standard DNS (account.dyn.com, Zone Level Services > realo.ca). Vultr IPs are static for the instance's lifetime, no DDNS needed |
| Dev/build VM | `realo@192.168.2.199` (NixOS aarch64, hostname realix) | Builds everything under x86_64 binfmt emulation. Work dir `/home/realo/Data/Work/MINIMAL-SERVER`. Its own NixOS config lives in the realix-iso repo (`/home/realo/Data/Work/realix-iso`, GitHub yodalf/realix-iso) and is updated with `sudo /etc/nixos/update.sh`. Key login is refused: `build.sh` needs `VM_PASS`. Also a tailnet node, `realix.ts.realo.ca` |
| Vultr API key | `~/.config/vultr/api_key` on the Mac (mode 600) | Access-controlled to the home IP 70.31.223.159 in the Vultr panel |

Installed closure: ~966 MiB (was 908 before headscale). Idle memory: ~135 MB used of 460 MB.

## How it fits together

- `modules/headscale.nix` is this machine's role (see the headscale section below). `modules/server.nix` is the generic box: virtio-only initrd, hybrid GRUB on `/dev/vda` with an ESP at `/boot`, systemd-networkd + DHCP, sshd (key only), zram swap, no firmware, no docs, no nixpkgs source in the closure, no Python (`nixos-rebuild` disabled, tiny `rebuild` script instead), no LVM, no guest agent.
- `modules/installer.nix` is the live ISO: `iso-image.nix` + `profiles/minimal.nix` only. It embeds the prebuilt server closure and a `vultr-install` script that partitions the disk (1 M BIOS boot, 256 M ESP, rest ext4 labelled `nixos`), runs `nixos-install --system <closure>` and copies the repo to `/etc/nixos`. No network needed.
- `flake.nix` pins nixpkgs `nixos-26.05`. `packages.x86_64-linux.{iso,server,src}`. `src` is an explicit file set so nothing stray in the directory ends up in the ISO.
- `build.sh` rsyncs the repo to the VM and runs everything there: `eval`, `server`, `iso`, `test`, `deploy`.

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

Since 2026-09-03 the server can also rebuild itself (2 GB swap file, see gotchas): copy the files and run `rebuild` there, which is what was done for that day's change:

```sh
tar cf - flake.nix flake.lock modules build.sh README.md test | ssh root@104.238.132.193 'rm -rf /etc/nixos && mkdir /etc/nixos && tar xf - -C /etc/nixos'
ssh root@104.238.132.193 rebuild dry-activate    # ~2.5 min cold, ~40 s warm; then `rebuild` (switch) or `rebuild boot`
```

Automatic upgrades and store maintenance (all in `server.nix`, deployed 2026-09-03, generation 5):

| Unit | When | What |
|------|------|------|
| `nixos-upgrade.timer` | daily 04:40 UTC + up to 30 min jitter, persistent | `nix flake update nixpkgs --flake /etc/nixos`, `rebuild boot`; reboots one minute later if kernel/modules/initrd changed, else live `switch-to-configuration switch`. `OnSuccess` starts `nix-gc.service` |
| `nix-gc.timer` | weekly | `nix-collect-garbage --delete-older-than 7d` |
| `nix-optimise.timer` | weekly | `nix-store --optimise` (on top of `auto-optimise-store`) |

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

## Gotchas learned today

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
- Firewall is on with 22, 80 and 443 open. Nightly upgrades and weekly gc/optimise are in place (see Day-to-day); no monitoring, so a failed `nixos-upgrade.service` goes unnoticed unless you look at the journal. **No backup of `/var/lib/headscale`** (SQLite db, noise key, ACME cache): losing it means re-registering every node.
- Disk: 3.3 GB used of 9.5 after the swap file and the nixpkgs source; each nightly upgrade that changes nixpkgs adds a generation until gc removes it after 7 days.
- The QEMU expect test (`test/qemu-boot-test.sh`) prompt patterns were fixed but the script has not been run to completion since; it also now requires `CONSOLE_PASSWORD` because the server has no password.
- Possible further trimming, not done: a custom kernel config (the 145 MB module tree is the single largest item) and dropping git/vim (~95 MB).

## Headscale (branch `headscale`, deployed 2026-09-02)

`modules/headscale.nix`, imported by the `server` config in `flake.nix`,
enables `services.headscale` (headscale 0.28.0 from nixpkgs 26.05) and sets
`networking.hostName = "headscale"` (server.nix's hostname is now a
`mkDefault`). Settings that matter:

| Setting | Value | Why |
|---------|-------|-----|
| `server_url` | `https://hs.realo.ca` | public control-server address (`fqdn` at the top of the module) |
| listener | `0.0.0.0:443` | module grants `CAP_NET_BIND_SERVICE` for ports < 1024 |
| TLS | `tls_letsencrypt_hostname` + HTTP-01 on port 80 | headscale's built-in ACME client; cert cached in `/var/lib/headscale/.cache`, renews itself. Current cert expires 2026-12-01 |
| `dns.base_domain` | `ts.realo.ca` (`baseDomain` in the module) | MagicDNS suffix, tailnet-internal only, no public record. Must differ from and not be a parent of hs.realo.ca |
| `dns.nameservers.global` | 1.1.1.1, 1.0.0.1 with `override_local_dns` | clients use these while connected |
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

Not done: backups of `/var/lib/headscale`; an ACL policy (all nodes of
`realo` can reach each other, which is the default).
