# Handoff: minimal NixOS server on Vultr

Date: 2026-09-02. State at handoff: one server installed, verified and deployed to.

## What exists

| Thing | Where | Notes |
|-------|-------|-------|
| Config repo | `~/Work/MINIMAL-NIXOS` on the Mac, mirror at https://github.com/yodalf/MINIMAL-NIXOS (public) | `main` branch, all work committed and pushed |
| Installer ISO | GitHub release `v0.1`, also `out/` locally and `result/` on the dev VM | 497 MB, x86_64, hybrid BIOS+UEFI, installs offline |
| Vultr instance | `minimal-server`, id `78bb9d0c-b470-4709-8987-ae2be76d2db2`, **104.238.132.193**, plan `vc2-1c-0.5gb` (1 vCPU, 512 MB, 10 GB), region `ewr` | $3.50/month, booted in legacy BIOS mode, generation 1 active |
| Dev/build VM | `realo@192.168.2.199` (NixOS aarch64, hostname realix) | Builds everything under x86_64 binfmt emulation. Work dir `/home/realo/Data/Work/MINIMAL-SERVER`. Its own NixOS config is off limits |
| Vultr API key | `~/.config/vultr/api_key` on the Mac (mode 600) | Access-controlled to the home IP 70.31.223.159 in the Vultr panel |

Installed closure: ~908 MiB. Idle memory: ~110 MB used of 460 MB.

## How it fits together

- `modules/server.nix` is the installed system: virtio-only initrd, hybrid GRUB on `/dev/vda` with an ESP at `/boot`, systemd-networkd + DHCP, sshd (key only), zram swap, no firmware, no docs, no nixpkgs source in the closure, no Python (`nixos-rebuild` disabled, tiny `rebuild` script instead), no LVM, no guest agent.
- `modules/installer.nix` is the live ISO: `iso-image.nix` + `profiles/minimal.nix` only. It embeds the prebuilt server closure and a `vultr-install` script that partitions the disk (1 M BIOS boot, 256 M ESP, rest ext4 labelled `nixos`), runs `nixos-install --system <closure>` and copies the repo to `/etc/nixos`. No network needed.
- `flake.nix` pins nixpkgs `nixos-26.05`. `packages.x86_64-linux.{iso,server,src}`. `src` is an explicit file set so nothing stray in the directory ends up in the ISO.
- `build.sh` rsyncs the repo to the VM and runs everything there: `eval`, `server`, `iso`, `test`, `deploy`.

## Day-to-day

Change the config and deploy (the server never evaluates or builds anything; it only receives a closure):

```sh
vim modules/server.nix
SERVER=root@104.238.132.193 VM_PASS=<vm password> ./build.sh deploy         # switch now
SERVER=root@104.238.132.193 VM_PASS=<vm password> ./build.sh deploy boot    # next reboot
git commit -am "..." && git push
```

Under the hood that is `nixos-rebuild switch --flake .#server --target-host root@<ip>` on the dev VM, then a refresh of `/etc/nixos` on the server. Without `VM_PASS`, key-based ssh to the VM is used.

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

- Evaluating this config needs ~600 MB RAM, more than the 512 MB plan has. That is why the server never rebuilds itself. `rebuild` on the box exists as an emergency fallback only and will swap hard.
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
- Nothing runs on the server yet besides sshd. Firewall is on with only port 22 open. No automatic upgrades, no backups, no monitoring; `nix.gc` runs weekly.
- The QEMU expect test (`test/qemu-boot-test.sh`) prompt patterns were fixed but the script has not been run to completion since; it also now requires `CONSOLE_PASSWORD` because the server has no password.
- Possible further trimming, not done: a custom kernel config (the 145 MB module tree is the single largest item) and dropping git/vim (~95 MB).
