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
`real@realo.ca`, HTTP-01 through nginx (`enableACME`). The certificate was
issued on 2026-09-03 right after the `realo.ca` A record (Dyn) was moved to
64.176.212.253 (`systemctl start acme-order-renew-realo.ca.service`, 7 s);
it expires 2026-12-02 and `acme-renew-realo.ca.timer` renews it daily as
needed. If an order ever fails ("Failed to fetch certificates"), nginx keeps
serving a self-signed placeholder and the timer retries daily, which stays
well under Let's Encrypt's 5 failed validations per hour; check
`journalctl -u acme-order-renew-realo.ca.service`.

Self-maintenance verified 2026-09-03 16:30 UTC with a manual
`systemctl start nixos-upgrade`: 5 min 13 s wall (most of it unpacking
nixpkgs into the git cache), 262 MB resident + 533 MB swap peak, nixpkgs was
unchanged so it re-activated the same generation without a reboot, then
`nix-gc` ran via `OnSuccess` (4498 paths, 202 MiB freed; disk 3.9 -> 3.3 GB).
The box answers ssh slowly (10 s+) while the upgrade evaluates; use a
generous `ConnectTimeout`. Timers: `nix-gc` daily ~00:00 UTC,
`nixos-upgrade` daily ~04:40 UTC, `nix-optimise` weekly, all enabled.

Access: ssh as root works from the dev VM (its "LOCK" key). The install was
done by hand from the console/VM: `echo YES | vultr-install /dev/vda`, then
`POST /v2/instances/<id>/iso/detach` from the Mac, then one
`SERVER=root@64.176.212.253 VM_PASS=... ./build.sh deploy` (which found the
ISO's closure already active). Verified 2026-09-03: hostname `realo-ca`,
nginx listening on 80/443, http redirects to https, the placeholder page is
served, ping ok, 3.1 GB of 9.5 used, 118 MB memory used.

Content (migrated 2026-09-03): the site is the Hugo site from the old
instance `totos` (45.77.78.141, Arch Linux, compose project
`/home/realo/AGORA/agora`, served there by `hugo server` behind Traefik).
Built once on the old box with its `klakegg/hugo:ext-pandoc` image (31 pages,
3 MB) and copied here:

| Where | What |
|-------|------|
| `/var/www/realo.ca` | the built site (root-owned, world-readable), what nginx serves |
| `/home/realo/AGORA` | the whole tree from the old box: the `agora` Hugo source (git repo, themes, `ARCHIVE`, one uncommitted change in `content/project/_index.md`), 27 MB, owned by realo |

The source repo's remote is `git@gitlab.com:realo/agora.git` (private,
switched from https on 2026-09-03). The box has no GitLab credential: push by
forwarding the Mac's agent through the dev VM (`ssh -A` on both hops, the
Mac's ed25519 key is registered at GitLab) and running `git push` as root
with `-c safe.directory=/home/realo/AGORA/agora`, then `chown -R realo:users
.git`. Commits are made as realo (`sudo -u realo git -c user.name=... -c
user.email=... commit`). Do not put `-n` in `GIT_SSH_COMMAND`: git needs
ssh's stdin and GitLab then reports "user canceled the push".

There is no hugo on this box. To publish a change: edit the source somewhere
with hugo (the old box's docker image, or hugo on the Mac/dev VM), build with
`hugo -d <dir>` (baseurl is `/`, so no URL to fix), and copy the output over
`/var/www/realo.ca` via the dev VM (`tar | ssh root@64.176.212.253`, the
server has no rsync).

Old box: `totos` ran `ddclient`, which kept setting the `realo.ca` A record
at Dyn to 45.77.78.141. The instance was stopped on 2026-09-03 (ddclient was
not disabled inside it: the realo account's sudo password is not known to
this workflow). If it is ever started again, disable ddclient first or it
will move the record back. The new box needs no ddclient: Vultr IPs are
static for the instance's life.

Not done: `www.realo.ca` and `whoami.realo.ca` (the old Traefik rules), the
choice of a final web server, and a backup of `/home/realo/AGORA` beyond the
copy still sitting on the old instance.
