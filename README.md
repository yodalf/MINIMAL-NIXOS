# MINIMAL-NIXOS

A deliberately small, text-only NixOS configuration for a generic server VM
on [Vultr](https://www.vultr.com), plus a custom installer ISO that puts it on
the instance's disk with no network access needed during the install.

Closure of the installed system: **~900 MiB** (a stock `nixos-generate-config`
server on the same nixpkgs is roughly 2x that).

## Layout

| File | Purpose |
|------|---------|
| `flake.nix` | Pins nixpkgs `nixos-26.05`; exposes `server` and `installer` configs and the `iso` package |
| `modules/server.nix` | The system that gets installed. Add services here or in a new module |
| `modules/installer.nix` | Live ISO carrying the prebuilt `server` closure and a `vultr-install` script |
| `build.sh` | Syncs the repo to the NixOS dev VM and builds there (the ISO is x86_64; the VM builds it via binfmt emulation) |

## Build

The repo is built on the dev VM in `/home/realo/Data/Work/MINIMAL-SERVER`:

```sh
VM_PASS=... ./build.sh eval     # evaluate only, catches option errors fast
VM_PASS=... ./build.sh server   # build the server closure and print its size
VM_PASS=... ./build.sh iso      # build the ISO and copy it to ./out/
```

Without `VM_PASS`, plain key-based ssh is used. `VM_HOST` and `VM_DIR`
override the defaults.

## Deploy on Vultr

1. Put `out/nixos-vultr-*.iso` somewhere reachable by URL and add it in the
   Vultr panel under *Orchestration > ISOs > Add ISO*.
2. Deploy a Cloud Compute instance and pick the ISO under *Custom ISO*. The
   ISO is hybrid (BIOS + UEFI); the installed GRUB is hybrid too, so either
   boot mode works.
3. Open the web console. It auto-logs in as root. Run:

   ```sh
   vultr-install          # partitions /dev/vda, copies the closure, installs GRUB
   ```

   Pass another device if the disk is not `/dev/vda` (virtio-scsi plans expose
   `/dev/sda`).
4. Detach the ISO in the panel and `reboot`.

Then `ssh realo@<ip>` or `ssh root@<ip>` with the key in `modules/server.nix`.
The `realo` account also has a console password (for the Vultr VNC console
only; SSH password auth is off). Change it by replacing `hashedPassword`
with the output of `openssl passwd -6`.

## Updating the server

The flake is copied to `/etc/nixos` at install time. On the server:

```sh
cd /etc/nixos && vim modules/server.nix
rebuild            # = nixos-rebuild switch --flake /etc/nixos#server
rebuild boot       # activate on next reboot instead
```

`rebuild` is a small shell script defined in `server.nix`. The real
`nixos-rebuild` is disabled because in nixpkgs 26.05 it is a Python program
that adds ~130 MB; set `system.tools.nixos-rebuild.enable = true` to get it
back.

To sync from this repo instead, `git clone` it to `/etc/nixos` (git is
installed) and run `rebuild`.

## What was cut, and why

| Cut | Saves | How |
|-----|-------|-----|
| linux-firmware and all firmware blobs | ~700 MB | `hardware.enableRedistributableFirmware = false`, `hardware.firmware = []` |
| nixpkgs source in the closure | ~250 MB | `nixpkgs.flake.setNixPath/setFlakeRegistry = false` |
| Python (via nixos-rebuild-ng) | ~130 MB | `system.tools.nixos-rebuild.enable = false`, replaced by `rebuild` |
| Manuals, man pages, info, nixos-option (man-db, groff) | ~60 MB | `documentation.*`, `system.tools.nixos-option.enable = false` |
| QEMU guest agent (qemu-ga, glib) | ~20 MB | `services.qemuGuest.enable = false` |
| systemd-importd (gnupg, openldap) | ~17 MB | `systemd.services.systemd-importd.enable = false` |
| perl default packages, LVM, udisks2, fontconfig, xdg, containers | ~30 MB | `profiles/minimal.nix`, `services.lvm.enable = false`, `boot.enableContainers = false` |
| All locales except en_US | ~200 MB | `i18n.supportedLocales` |
| Every kernel module in the initrd except virtio + sd_mod | initrd size | `boot.initrd.availableKernelModules` |

What is still there and why:

- **Kernel modules (~145 MB)**: the stock kernel's full module tree. Trimming
  it means building a custom kernel, which is very slow under emulation on the
  dev VM. Only virtio modules are loaded at boot; the rest just sit on disk.
- **perl (~55 MB)**: NixOS activation and the GRUB installer are Perl scripts.
  Going perl-less requires systemd-boot, which is UEFI-only.
- **Two GRUB builds (~60 MB)**: one BIOS, one EFI, for the hybrid boot loader.
  If you know the instance boots in legacy mode, set `efiSupport = false` and
  drop the `/boot` filesystem to save ~30 MB.
- **git-minimal + vim (~95 MB)**: convenience. Remove them from
  `environment.systemPackages` if you do not need an editor or git on the box
  (`nano` is disabled, so re-enable it or keep vim).
- **nix (~90 MB with boost/icu)**: needed to rebuild the server in place.
