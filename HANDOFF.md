# Handoff: realo.ca web server on Vultr (branch `realo-ca`)

Date: 2026-09-03 evening (branch created earlier the same day from `main`;
the generic handoff was first written 2026-09-02). State at handoff: one
server `realo-ca` installed from the v0.2 ISO and running generation 1,
NixOS 26.11pre from nixos-unstable, serving https://realo.ca with a Let's
Encrypt certificate and the Hugo site migrated from the old 2017 instance.
It upgrades itself nightly and collects garbage daily; both were exercised by
hand today. The old instance is stopped and fully backed up.

This branch is a permanent role branch like `headscale`: never merged into
`main` (the generic server); rebase or cherry-pick generic fixes from `main`
onto it. The headscale server (104.238.132.193) has its own handoff on its
branch.

## What exists

| Thing | Where | Notes |
|-------|-------|-------|
| Config repo | `~/Work/MINIMAL-NIXOS` on the Mac, mirror at https://github.com/yodalf/MINIMAL-NIXOS (public) | `main` = generic server, `headscale` and `realo-ca` = one deployed machine each. All pushed |
| Vultr instance | label `realo-ca`, id `9e8112d0-9fad-4bff-ab5a-1f68cf42ef54`, **64.176.212.253**, plan `vc2-1c-0.5gb` (1 vCPU, 512 MB, 10 GB), region `ewr`, IPv4 only | $3.50/month, legacy BIOS boot, OS hostname `realo-ca`, installed 2026-09-03 |
| Vultr firewall group | `realo-ca`, id `f6f326a0-38d9-46db-8b9c-a1375cd678c8`, attached at creation | inbound tcp 22, 80, 443 and ICMP from anywhere, all else dropped at Vultr's edge. Mirrors `networking.firewall` on the box: open a port in both places. The headscale instance has its own group `headscale` (`24b1ef7d-…`, same rules). The 2018 group `Basic` (also udp 1194, for the old WireGuard) is attached to nothing |
| DNS | `realo.ca` A -> 64.176.212.253 (TTL 60) | Dyn Standard DNS (account.dyn.com, Zone Level Services > realo.ca). Moved from 45.77.78.141 on 2026-09-03. No DDNS anywhere any more: Vultr IPs are static for the instance's life |
| Installer ISO v0.2 | GitHub release `v0.2` (530 MB, built from this branch), Vultr ISO id `1c4d24f5-9039-4ee5-99da-42b2e0f1f928`; also `out/` on the Mac | Installs this system offline. v0.1 (26.05, generic) is still registered at Vultr too; the account allows 2 ISOs, delete one before registering another |
| Site source | `/home/realo/AGORA/agora` on the server (git, `master`, remote `git@gitlab.com:realo/agora.git`, private); clone on the Mac at `~/Work/agora` | Hugo site. Both at 2d974ca and in sync with GitLab as of this handoff |
| Old instance backup | `~/Backups/totos/totos-2026-09-03.tgz` on the Mac (1.9 GB), copy in `~/.cache/minimal-nixos/totos/` on the dev VM | Everything of value from the 2017 box, see Loose ends |
| Dev/build VM | `realo@192.168.2.199` (NixOS aarch64, hostname realix, login shell fish) | Builds everything under x86_64 binfmt emulation. Work dir `/home/realo/Data/Work/MINIMAL-SERVER`. Key login refused: `build.sh` needs `VM_PASS`. Has root ssh to both Vultr servers (its "LOCK" key). Its own NixOS config is off limits |
| Vultr API key | `~/.config/vultr/api_key` on the Mac (mode 600) | Access-controlled to the home IP 70.31.223.159 in the Vultr panel |

Server figures after today's gc: 3.3 GB of 9.5 GB disk used (2 GB of it the
swap file), ~118 MB memory used of 460 idle, ~300 MB during an upgrade.

## How it fits together

- `modules/realo-ca.nix` is this machine's role (details in the realo.ca
  section). `modules/server.nix` is the generic box: virtio-only initrd,
  hybrid GRUB on `/dev/vda` with an ESP at `/boot`, systemd-networkd + DHCP,
  sshd (key only), zram swap plus a 2 GB swap file, no firmware, no docs, no
  nixpkgs source in the closure, no Python (`nixos-rebuild` disabled, tiny
  `rebuild` script instead), no LVM, no guest agent. Its hostname is a
  `mkDefault` so the role module can override it.
- `modules/installer.nix` is the live ISO: `iso-image.nix` +
  `profiles/minimal.nix` only. It embeds the prebuilt server closure and a
  `vultr-install` script that partitions the disk (1 M BIOS boot, 256 M ESP,
  rest ext4 labelled `nixos`), runs `nixos-install --system <closure>` and
  copies the repo to `/etc/nixos`. No network needed.
- `flake.nix` follows nixpkgs `nixos-unstable` (`system.stateVersion` stays
  26.05). `packages.x86_64-linux.{iso,server,src}`. `src` is an explicit
  file set so nothing stray in the directory ends up in the ISO.
- `build.sh` rsyncs the repo to the VM and runs everything there: `eval`,
  `server`, `iso`, `test`, `deploy`, `backup`. All evaluation and building
  happens on the dev VM; the server can rebuild itself but that path is for
  the nightly timer and emergencies (owner's preference: the hard work stays
  on the VM).

## Day-to-day

Change the config and deploy:

```sh
vim modules/realo-ca.nix
scp root@64.176.212.253:/etc/nixos/flake.lock .    # take the server's (nightly-updated) lock, see below
SERVER=root@64.176.212.253 VM_PASS=<vm password> ./build.sh deploy         # switch now
SERVER=root@64.176.212.253 VM_PASS=<vm password> ./build.sh deploy boot    # next reboot
git commit -am "..." && git push
```

Under the hood that is `nixos-rebuild switch --flake .#server --target-host
root@<ip>` on the dev VM, then a tar copy of the file set (flake, modules,
build.sh, README, test) to `/etc/nixos` on the server. The `scp` of the lock
file matters: `/etc/nixos/flake.lock` on the server moves ahead of the repo's
every night, and deploying the repo's older lock would downgrade nixpkgs.

Fallback only (not the normal flow): the server can rebuild itself. Copy the
files and run `rebuild` there:

```sh
tar cf - flake.nix flake.lock modules build.sh README.md test | ssh root@64.176.212.253 'rm -rf /etc/nixos && mkdir /etc/nixos && tar xf - -C /etc/nixos'
ssh root@64.176.212.253 rebuild dry-activate    # then `rebuild` (switch) or `rebuild boot`
```

Automatic upgrades and store maintenance (all in `server.nix`, all enabled
and verified on this box, see the realo.ca section):

| Unit | When | What |
|------|------|------|
| `nixos-upgrade.timer` | daily 04:40 UTC + up to 30 min jitter, persistent | `nix flake update nixpkgs --flake /etc/nixos`, `rebuild boot`; reboots one minute later if kernel/modules/initrd changed, else live `switch-to-configuration switch`. `OnSuccess` starts `nix-gc.service` |
| `nix-gc.timer` | daily 00:00 UTC + up to 30 min jitter, persistent | `nix-collect-garbage --delete-older-than 2d` |
| `nix-optimise.timer` | weekly | `nix-store --optimise` (on top of `auto-optimise-store`) |
| `acme-renew-realo.ca.timer` | daily | lego renewal of the realo.ca certificate when due |

It is a hand-written unit, not `system.autoUpgrade`: that module hardcodes
`nixos-rebuild` (127 MB of Python). Check on it with `journalctl -u
nixos-upgrade` and `systemctl list-timers`. There is no monitoring: a failed
run goes unnoticed unless someone looks.

Publish a change to the site (no hugo on the box):

```sh
cd ~/Work/agora && git pull                         # ssh remote, the Mac's key is at GitLab
# edit content/…, then build with hugo (baseurl is "/", nothing to fix):
hugo -d /tmp/site                                   # any hugo that the "academic" theme accepts; the old box used klakegg/hugo:ext-pandoc
git commit -am "..." && git push
# ship the output; the server has no rsync and the Mac cannot ssh to it directly, go through the VM:
tar -C /tmp/site -czf - . | ssh realo@192.168.2.199 'ssh root@64.176.212.253 "rm -rf /var/www/realo.ca.new && mkdir /var/www/realo.ca.new && tar -C /var/www/realo.ca.new -xzf - && mv /var/www/realo.ca /var/www/realo.ca.old && mv /var/www/realo.ca.new /var/www/realo.ca && rm -rf /var/www/realo.ca.old"'
ssh realo@192.168.2.199 'ssh root@64.176.212.253 "cd /home/realo/AGORA/agora && sudo -u realo git pull"'   # keep the server's copy of the source current
```

Rebuild the ISO (only needed for installing new machines; ~15 min under
emulation):

```sh
VM_PASS=... ./build.sh iso          # -> out/*.iso
gh release create v0.3 out/*.iso --target realo-ca   # the branch must be pushed first
```

Test an ISO without touching Vultr, on the dev VM in the repo dir:

```sh
test/qemu-manual.sh install   # boot ISO on a qcow2 disk, run vultr-install, poweroff
test/qemu-manual.sh boot      # boot the installed disk; ssh -p 2222 realo@192.168.2.199
UEFI=1 test/qemu-manual.sh …  # same with OVMF firmware
```

`test/qemu-boot-test.sh` is the scripted (expect) version. It has never
completed a full run; the manual script is proven.

Install a new Vultr server from the ISO (this is how realo-ca was made):

1. Register the ISO: Vultr needs a direct URL and does not follow redirects.
   Get the final URL with `curl -sI <github release asset url> | grep -i
   location` and POST it to `/v2/iso`. It downloads in under a minute.
2. `POST /v2/instances` with `region`, `plan`, `iso_id`, `label`,
   `hostname`, `firewall_group_id` and the two `sshkey_id`s (Mac ed25519
   `57ce1ead-…`, VM "LOCK" `f03ed3a4-…`). Create the firewall group first.
3. When `main_ip` is assigned and the ISO has booted, the owner logs in and
   runs `echo YES | vultr-install /dev/vda` (owner's step: the Mac does not
   ssh to a fresh instance; the dev VM can, afterwards).
4. `umount -R /mnt` in the installer, `POST /v2/instances/<id>/iso/detach`
   (Vultr reboots the instance), wait for the role hostname on ssh from the
   VM, then `build.sh deploy` once.

Rescue: attach the ISO to the instance again and boot it. It auto-logs in as
root on the console and accepts ssh with the usual keys; mount `/dev/vda3` at
`/mnt` and `/dev/vda2` at `/mnt/boot`.

## Access

- From the dev VM: `ssh root@64.176.212.253` or `ssh realo@…` (its "LOCK"
  key). From the Mac the ed25519 key is also authorized, but the owner's
  practice is to go through the VM. `realo` is in `wheel`, sudo needs no
  password.
- Remote scripts through the VM: `sshpass -p … ssh -o PubkeyAuthentication=no
  -o PreferredAuthentications=password realo@192.168.2.199 'bash -s' <<EOF …
  EOF`, and inside it `ssh -n root@64.176.212.253 …` for one-liners; without
  `-n` the inner ssh eats the rest of the script. For a nested `bash -s`
  heredoc on the server, drop `-n` and don't pipe anything else into it.
- There is no password on any account. The Vultr VNC console cannot log in to
  the installed system; use the ISO as a rescue disk instead. To allow console
  login set `users.users.realo.hashedPassword` (output of `openssl passwd -6`)
  and deploy.
- Host keys: the installer and the installed system have different host keys
  for the same IP. The ssh calls in the scripts use
  `StrictHostKeyChecking=accept-new`; the VM's `known_hosts` entry for
  64.176.212.253 disappeared once during the day (cause unknown), re-accepting
  fixed it.
- While `nixos-upgrade` evaluates, sshd answers slowly (10 s or more); a
  5 s `ConnectTimeout` reports the box as down when it is not.

## realo.ca

`modules/realo-ca.nix`, imported by the `server` config in `flake.nix`, sets
`networking.hostName = "realo-ca"` and runs nginx: `forceSSL` virtual host
`realo.ca`, document root `/var/www/realo.ca`, ports 80 and 443 open on the
box (and in the Vultr group). tmpfiles creates the document root once with a
placeholder page and never overwrites it; the real site was copied over it.
The web server is a placeholder choice: replace the `services.nginx` block
with whatever is decided; the ACME part stays as long as something on :80
serves `/.well-known/acme-challenge/` from the acme module's webroot.

TLS: `security.acme` (lego) with `acceptTerms`, account email
`real@realo.ca`, HTTP-01 through nginx (`enableACME`). Issued 2026-09-03
right after the A record moved (`systemctl start
acme-order-renew-realo.ca.service`, 7 s); expires 2026-12-02, renewed by
`acme-renew-realo.ca.timer`. If an order fails ("Failed to fetch
certificates"), nginx keeps a self-signed placeholder and the timer retries
daily, well under Let's Encrypt's 5 failed validations per hostname per hour;
`journalctl -u acme-order-renew-realo.ca.service` says why.

Self-maintenance, verified 2026-09-03 16:30 UTC with a manual `systemctl
start nixos-upgrade`: 5 min 13 s wall (most of it unpacking nixpkgs into the
git cache), 262 MB resident + 533 MB swap peak, nixpkgs unchanged so it
re-activated the same generation without a reboot, then `nix-gc` ran via
`OnSuccess` (4498 paths, 202 MiB freed, disk 3.9 -> 3.3 GB). nginx stayed
up throughout.

Content: the Hugo site (title "Réal Ouellet", theme "academic", 31 pages,
3 MB built) from the old instance, where it ran as `hugo server` in a
`klakegg/hugo:ext-pandoc` container behind Traefik.

| Where | What |
|-------|------|
| `/var/www/realo.ca` | the built site (root-owned, world-readable), what nginx serves. Built 2026-09-03 on the old box, then hand-patched twice (below) |
| `/home/realo/AGORA` | the whole tree from the old box, 27 MB, owned by realo: the `agora` Hugo source (git, clean, at 2d974ca) plus its `ARCHIVE` |

Git on the server: commit as realo (`sudo -u realo git -c "user.name=Real
Ouellet" -c user.email=real@realo.ca commit`). The box has no GitLab
credential; to push from there forward the Mac's agent through the VM (`ssh
-A` on both hops; `ssh-add ~/.ssh/id_ed25519` on the Mac first) and run `git
push` as root with `-c safe.directory=/home/realo/AGORA/agora`, then `chown
-R realo:users .git`. Do not put `-n` in `GIT_SSH_COMMAND`: git needs ssh's
stdin and GitLab then reports "user canceled the push". Pushing from the Mac
clone is simpler.

Today's edits, made straight on the served files and also in git, so a
rebuild from `master` reproduces them: the Speak White YouTube link on the
Links page (61f5bef), and the removal of a stray "[github:8748457]" from the
projects subtitle in `project/index.html`. That text came from an
uncommitted edit in the old box's working tree that the build picked up; it
was committed by mistake (6472b42) and reverted (2d974ca). Lesson: build
from a clean checkout.

Not done: `www.realo.ca` and `whoami.realo.ca` (the old Traefik rules; no
DNS records were checked for them), the choice of a final web server, and
any off-box backup of the server itself. The site source is safe in GitLab
and on the Mac; `/var/lib/acme` is re-creatable; nothing else on the box is
unique.

## Gotchas learned

- Evaluating this config needs ~750 MB (230 MB resident, 550 MB swap peak on
  headscale; 262 + 533 here). On zram alone it cannot fit; the 2 GB
  `/swapfile` (`swapDevices` in server.nix, created by NixOS at boot,
  priority below zram) makes it work.
- `/etc/nixos` on a server was once found stale (headscale box, 2026-09-03):
  the deploy refresh is now a plain tar copy. If in doubt, `diff -r` the repo
  against `/etc/nixos` before running `rebuild` on the box.
- Anything in the repo directory on the dev VM ends up inside the ISO if it
  is in the `src` file set; keep junk out of
  `/home/realo/Data/Work/MINIMAL-SERVER`. `build.sh` excludes
  `*.log`/`*.qcow2`.
- `nixos-rebuild build` in that directory overwrites the `result` symlink
  that `build.sh iso` also uses; `nix build .#packages.x86_64-linux.iso
  --out-link result` restores it.
- The dev VM's login shell is fish: wrap remote commands in `bash -c` or
  `bash -s`. sshpass needs `-o PubkeyAuthentication=no -o
  PreferredAuthentications=password` or the Mac's agent keys trip "too many
  authentication failures". rsync from the VM to the Mac misbehaved once;
  scp worked.
- Vultr custom ISOs boot in legacy BIOS mode on this plan (the installed GRUB
  covers both modes anyway). Disk is virtio-blk (`/dev/vda`), network `ens3`
  with DHCP. Attaching an ISO to a stopped instance starts it; detaching one
  restarts it.
- GitHub release URLs fail on Vultr (redirect). The signed CDN URL expires
  after ~1 hour, so register it right after fetching it. `gh release create
  --target <branch>` needs the branch pushed.
- The kernel console order is `console=tty0 console=ttyS0`: the serial port
  is the primary console; the VNC console shows the kernel log and a getty.
- Let's Encrypt HTTP-01 needs the A record in place first; a config that
  requests a certificate can be deployed before that (it fails softly), but
  each attempt counts toward the 5-per-hour limit.
- The Mac's filesystem is case-insensitive: `~/Work/agora` and
  `~/Work/AGORA` are the same directory.

## Loose ends

- **Old instance `totos`** (unlabeled, 45.77.78.141, id
  `b3506f78-9680-423f-85c3-a4a24b21d147`, `vc2-1c-0.5gb`, 20 GB disk, Arch
  Linux, docker) is stopped, no ISO attached, still billed $3.50/month.
  Destroy it when the backup is judged sufficient. Its disk was inventoried
  and archived on 2026-09-03 by booting it from the v0.2 installer ISO and
  mounting `/dev/vda1` read-only (that way its `ddclient` never runs).
  Backup: `~/Backups/totos/totos-2026-09-03.tgz` (1.9 GB, 78060 entries,
  sha256 starts `5c525299`), holding `/home/realo` (minus google-cloud-sdk,
  `.cache`, `.npm`), `/root`, `/srv` (the pre-Hugo static sites `http`,
  `http.JKL`, `http.SHOW`, `http_2017-05-14`), `/srv.ORI`, `/etc`
  (`ddclient.conf` with the Dyn login, httpd config, `letsencrypt/`,
  `systemd/system/realo.timer`), `/opt`. Notable inside `/home/realo`:
  `WORK/WWW/Hugo` (1.8 GB of older Hugo trees) and `WORK/WWW/srv.tgz`,
  `WORK/KRAKEN`, `WORK/VPN`, `WORK/vmkit`,
  `WORK/compute-archlinux-image-builder` (git), `WG/` + `wg0.conf` (a
  WireGuard server on UDP 1194 with 9 named peers, private keys included;
  same under `/root/WG`), `.ssh/google_compute_engine`, `.config/gcloud`
  credentials, `hello_owl` (a WebAssembly demo). Not backed up: `/var` (2 GB
  logs, 1.5 GB pacman cache, 760 MB docker images) and `/usr`. If it must be
  booted again: attach the ISO (never let Arch boot, ddclient would set
  realo.ca back to 45.77.78.141 within about 5 minutes); to stop it, `POST
  /instances/<id>/halt` right after `iso/detach`, since the detach restarts
  it (the installer's own `poweroff` did not register with Vultr).
- The `Basic` firewall group from 2018 and the v0.1 ISO can be deleted from
  the Vultr account; nothing uses them.
- No monitoring on either server; a failed `nixos-upgrade`,
  `acme-order-renew` or (on headscale) `headscale-backup` goes unnoticed
  unless someone reads the journal.
- The QEMU expect test (`test/qemu-boot-test.sh`) has not been run to
  completion; it also now requires `CONSOLE_PASSWORD` because the server has
  no password.
- Possible further trimming, not done: a custom kernel config (the 145 MB
  module tree is the single largest item) and dropping git/vim (~95 MB).
  git is used on this box for the site source, so keep it here.
