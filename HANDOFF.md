# Handoff: minimal NixOS server on Vultr

Date: 2026-09-03 (first written 2026-09-02). State at handoff: one server installed and deployed to, generation 8, NixOS 26.11pre from nixos-unstable; it upgrades itself nightly and collects garbage daily. The live instance runs the `headscale` branch, which has its own handoff.

## What exists

| Thing | Where | Notes |
|-------|-------|-------|
| Config repo | `~/Work/MINIMAL-NIXOS` on the Mac, mirror at https://github.com/yodalf/MINIMAL-NIXOS (public) | `main` branch, all work committed and pushed |
| Installer ISO | GitHub release `v0.1`, also `out/` locally and `result/` on the dev VM | 497 MB, x86_64, hybrid BIOS+UEFI, installs offline |
| Vultr instance (this branch) | label `realo-ca`, id `9e8112d0-9fad-4bff-ab5a-1f68cf42ef54`, **64.176.212.253**, plan `vc2-1c-0.5gb` (1 vCPU, 512 MB, 10 GB), region `ewr`, firewall group `realo-ca` (`f6f326a0-38d9-46db-8b9c-a1375cd678c8`: tcp 22/80/443 + ICMP, IPv4 only) | $3.50/month, legacy BIOS boot, installed 2026-09-03 from the v0.2 ISO, generation 1. See the realo.ca section at the end |
| Vultr instance (headscale) | label `headscale`, id `78bb9d0c-b470-4709-8987-ae2be76d2db2`, **104.238.132.193**, same plan and region | Runs the `headscale` branch, which has its own handoff |
| Installer ISO v0.2 | GitHub release `v0.2` (530 MB, built from this branch), Vultr ISO id `1c4d24f5-9039-4ee5-99da-42b2e0f1f928` | Installs the realo-ca system offline. v0.1 (26.05, generic) is still registered at Vultr too; the account allows 2 ISOs, so delete one before registering another |
| Dev/build VM | `realo@192.168.2.199` (NixOS aarch64, hostname realix) | Builds everything under x86_64 binfmt emulation. Work dir `/home/realo/Data/Work/MINIMAL-SERVER`. Its own NixOS config is off limits |
| Vultr API key | `~/.config/vultr/api_key` on the Mac (mode 600) | Access-controlled to the home IP 70.31.223.159 in the Vultr panel |

Installed closure: ~976 MiB on nixos-unstable (908 on 26.05 without headscale). Idle memory: ~135 MB used of 460 MB. Disk: 4.3 GB of 9.5 used (2 GB of it the swap file).

## How it fits together

- `modules/server.nix` is the installed system: virtio-only initrd, hybrid GRUB on `/dev/vda` with an ESP at `/boot`, systemd-networkd + DHCP, sshd (key only), zram swap, no firmware, no docs, no nixpkgs source in the closure, no Python (`nixos-rebuild` disabled, tiny `rebuild` script instead), no LVM, no guest agent.
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

Automatic upgrades and store maintenance (all in `server.nix`, first deployed 2026-09-03 as generation 5; gc made daily and retention cut to 2 days later that day, generation 8):

| Unit | When | What |
|------|------|------|
| `nixos-upgrade.timer` | daily 04:40 UTC + up to 30 min jitter, persistent | `nix flake update nixpkgs --flake /etc/nixos`, `rebuild boot`; reboots one minute later if kernel/modules/initrd changed, else live `switch-to-configuration switch`. `OnSuccess` starts `nix-gc.service` |
| `nix-gc.timer` | daily 00:00 UTC + up to 30 min jitter, persistent | `nix-collect-garbage --delete-older-than 2d` (tested by hand 2026-09-03: 651 MB freed, 18 s; generations under 2 days are kept) |
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
- On `main` nothing but sshd runs and only port 22 is open (the live instance runs the `headscale` branch, which has its own handoff). Nightly upgrades, daily gc and weekly optimise are in place (see Day-to-day); no monitoring, so a failed `nixos-upgrade.service` goes unnoticed unless you look at the journal. **No backup of `/var/lib/headscale`** (SQLite db, noise key, ACME cache): losing it means re-registering every node.
- Disk: 4.3 GB used of 9.5 (swap file, nixpkgs source, the 26.05 and 26.11 closures side by side); each nightly upgrade that changes nixpkgs adds a generation until gc removes it after 2 days. Generations 1 to 7 (the 26.05 ones) go at the 2026-09-05 run.
- The QEMU expect test (`test/qemu-boot-test.sh`) prompt patterns were fixed but the script has not been run to completion since; it also now requires `CONSOLE_PASSWORD` because the server has no password.
- Possible further trimming, not done: a custom kernel config (the 145 MB module tree is the single largest item) and dropping git/vim (~95 MB).

## realo.ca (branch `realo-ca`, installed 2026-09-03)

`modules/realo-ca.nix`, imported by the `server` config in `flake.nix`, sets
`networking.hostName = "realo-ca"` (server.nix's hostname is a `mkDefault`)
and runs nginx: `forceSSL` virtual host `realo.ca`, document root
`/var/www/realo.ca` (created once by tmpfiles with a placeholder page, never
overwritten afterwards; put real content there), ports 80 and 443 open on the
box and in the Vultr firewall group `realo-ca`. The web server is a
placeholder choice: replace the `services.nginx` block with whatever is
decided; the ACME part stays as long as something on :80 serves
`/.well-known/acme-challenge/` from the acme module's webroot.

TLS: `security.acme` (lego) with `acceptTerms`, account email
`real@realo.ca`, HTTP-01 through nginx (`enableACME`). **The certificate is
not issued yet**: on 2026-09-03 `realo.ca` still resolves to 45.77.78.141, the
old stopped 2017 instance, so `acme-order-renew-realo.ca.service` fails
("Failed to fetch certificates") and nginx serves a self-signed placeholder.
The unit has no automatic restart; `acme-renew-realo.ca.timer` retries daily,
which stays well under Let's Encrypt's 5 failed validations per hour. To get
the real certificate:

```sh
# 1. at Dyn: realo.ca A -> 64.176.212.253, then wait until this returns it
dig +short realo.ca
# 2. on the server (from the dev VM, see Access below)
systemctl start acme-order-renew-realo.ca.service && systemctl status acme-order-renew-realo.ca.service
curl -sI https://realo.ca | head -1
```

Access: ssh as root works from the dev VM (its "LOCK" key). The install was
done by hand from the console/VM: `echo YES | vultr-install /dev/vda`, then
`POST /v2/instances/<id>/iso/detach` from the Mac, then one
`SERVER=root@64.176.212.253 VM_PASS=... ./build.sh deploy` (which found the
ISO's closure already active). Verified 2026-09-03: hostname `realo-ca`,
nginx listening on 80/443, http redirects to https, the placeholder page is
served, ping ok, 3.1 GB of 9.5 used, 118 MB memory used.

Not done: real content, the choice of web server, `www.realo.ca`, and
anything backup-related (nothing on the box needs one until content exists;
`/var/lib/acme` is re-creatable).
