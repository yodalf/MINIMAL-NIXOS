# MINIMAL-NIXOS

A deliberately small, text-only NixOS configuration for a generic server VM
on [Vultr](https://www.vultr.com), plus a custom installer ISO that puts it on
the instance's disk with no network access needed during the install.

Closure of the installed system: **~900 MiB**. Installer ISO: **~500 MB**
(the ISO also holds the installer's own live system and is zstd-compressed).

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
VM_PASS=... ./build.sh test     # boot the ISO in QEMU on the VM, install, reboot, log in
```

To do the same by hand on the VM (serial console, you type the commands):

```sh
test/qemu-manual.sh install     # boots the ISO; run vultr-install, then poweroff
test/qemu-manual.sh boot        # boots the installed disk; login realo, or ssh -p 2222
UEFI=1 test/qemu-manual.sh ...  # same, but firmware is OVMF instead of SeaBIOS
test/qemu-manual.sh reset       # throw the disk image away
```

`test` runs `test/qemu-boot-test.sh`: an expect script that boots the ISO on
an 8 GB virtio disk under QEMU (TCG, so it is slow but works on the aarch64
VM), runs `vultr-install`, reboots from the disk and logs in as `realo` over
the serial console. It prints `PASS` or a `FAIL:` reason.

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

Then `ssh realo@<ip>` or `ssh root@<ip>` with a key from `sshKeys` in
`modules/server.nix`. There are no passwords at all: SSH is key-only and
`sudo` asks for none. The Vultr VNC console therefore cannot log in to the
installed system; boot the ISO again if you need a rescue shell. To allow
console login, set `users.users.realo.hashedPassword` to the output of
`openssl passwd -6`.

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

Evaluating the config takes ~600 MB of RAM, so on a 1 GB instance the
intended workflow is to never rebuild on the server. Deploy from the dev VM
with `nixos-rebuild --target-host`, which builds the x86_64 closure there
(binfmt emulation), copies it with `nix copy` and activates it over SSH:

```sh
SERVER=root@<ip> VM_PASS=... ./build.sh deploy        # switch now
SERVER=root@<ip> VM_PASS=... ./build.sh deploy boot   # activate on next reboot
```

Or directly on the dev VM, in the repo directory:

```sh
nixos-rebuild switch --flake .#server --target-host root@<ip>
```

The dev VM's own SSH key is in `sshKeys` for this purpose. `build.sh deploy`
also refreshes `/etc/nixos` on the server with the deployed sources, so the
in-place `rebuild` remains available as a fallback.

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
