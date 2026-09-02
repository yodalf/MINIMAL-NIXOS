#!/usr/bin/env bash
#
# Boot the installer ISO or the installed disk in QEMU, interactively, on the
# serial console. Run it on the dev VM in the repo directory.
#
#   test/qemu-manual.sh install [iso]   boot the ISO with a fresh/existing disk
#                                       -> at the root prompt: vultr-install, YES, poweroff
#   test/qemu-manual.sh boot            boot the installed disk
#   test/qemu-manual.sh reset           delete the disk image
#
# Environment:
#   DISK=~/.cache/minimal-nixos/disk.qcow2   disk image (created if missing, 8G)
#   UEFI=1            boot with OVMF instead of SeaBIOS (tests the EFI GRUB path)
#   MEM=2048 SMP=2    guest memory (MB) and cpus
#   SSH_PORT=2222     host port forwarded to guest port 22 (ssh -p 2222 realo@<vm-ip>)
#
# Ctrl-a x quits QEMU. Console login: realo / the hashedPassword in server.nix.
set -euo pipefail
cd "$(dirname "$0")/.."

NIXPKGS="github:NixOS/nixpkgs/a3116115851d68b8952a2a4221cc25a84e56b532"
DISK="${DISK:-${XDG_CACHE_HOME:-$HOME/.cache}/minimal-nixos/disk.qcow2}"
mkdir -p "$(dirname "$DISK")"
MEM="${MEM:-2048}"
SMP="${SMP:-2}"
SSH_PORT="${SSH_PORT:-2222}"
action="${1:-}"

# Re-exec inside a nix shell that has qemu (and OVMF for UEFI) if needed.
if ! command -v qemu-system-x86_64 >/dev/null; then
  pkgs=("$NIXPKGS#qemu")
  [[ -n "${UEFI:-}" ]] && pkgs+=("$NIXPKGS#OVMF.fd")
  exec nix shell "${pkgs[@]}" --command "$0" "$@"
fi

case "$action" in
  install|boot) ;;
  reset) rm -f "$DISK"; echo "removed $DISK"; exit 0 ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac

[[ -e "$DISK" ]] || qemu-img create -f qcow2 "$DISK" 8G

args=(-m "$MEM" -smp "$SMP" -nographic
      -drive "file=$DISK,if=virtio,format=qcow2"
      -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22" -device virtio-net-pci,netdev=n0)

if [[ -n "${UEFI:-}" ]]; then
  ovmf=$(nix build --no-link --print-out-paths "$NIXPKGS#OVMF.fd")
  args+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf/FV/OVMF.fd")
fi

if [[ $action == install ]]; then
  iso="${2:-$(ls result/iso/*.iso 2>/dev/null | head -1)}"
  [[ -f "$iso" ]] || { echo "no ISO found; build it first or pass its path" >&2; exit 1; }
  args+=(-cdrom "$iso" -boot d -no-reboot)
  echo ">>> booting $iso  (disk: $DISK, $([[ -n ${UEFI:-} ]] && echo UEFI || echo BIOS))"
  echo ">>> at the root prompt run: vultr-install   then: poweroff"
else
  echo ">>> booting $DISK  ($([[ -n ${UEFI:-} ]] && echo UEFI || echo BIOS)); ssh -p $SSH_PORT realo@<this-host>"
fi
echo ">>> Ctrl-a x quits QEMU"
exec qemu-system-x86_64 "${args[@]}"
