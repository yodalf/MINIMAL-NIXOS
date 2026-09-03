#!/usr/bin/env bash
#
# Sync this repo to the NixOS dev VM and build the Vultr installer ISO there
# (the ISO is x86_64; the VM builds it via binfmt emulation).
#
#   ./build.sh            build the ISO, copy it to ./out/
#   ./build.sh server     only build the server closure and print its size
#   ./build.sh eval       just evaluate (fast syntax/option check)
#   ./build.sh test       boot the built ISO in QEMU on the VM, install, reboot, log in
#   ./build.sh deploy [switch|boot|test|dry-activate]
#                         nixos-rebuild --target-host from the dev VM: build
#                         there, nix copy to the server, activate remotely.
#                         Needs SERVER=root@<ip>. Nothing is evaluated or built
#                         on the server itself, so it works on 1 GB of RAM.
#   ./build.sh backup     pull the server's /var/backups (the snapshots its
#                         timers write) to $BACKUP_DIR (default ~/Backups/<host>).
#                         Needs SERVER=root@<ip>; does not touch the dev VM.
#
# Set VM_PASS to use sshpass; otherwise plain key-based ssh is used.
set -euo pipefail

VM_HOST="${VM_HOST:-realo@192.168.2.199}"
VM_DIR="${VM_DIR:-/home/realo/Data/Work/MINIMAL-SERVER}"
SSH=(ssh -o StrictHostKeyChecking=no)
RSYNC=(rsync)
if [[ -n "${VM_PASS:-}" ]]; then
  SSH=(sshpass -p "$VM_PASS" "${SSH[@]}")
  RSYNC=(sshpass -p "$VM_PASS" rsync)
fi

cd "$(dirname "$0")"

# Server-only action, no VM involved.
if [[ "${1:-}" == backup ]]; then
  SERVER="${SERVER:?set SERVER=root@<server-ip>}"
  host=$(ssh -o StrictHostKeyChecking=accept-new "$SERVER" hostname)
  dest="${BACKUP_DIR:-$HOME/Backups/$host}"
  mkdir -p "$dest"
  # The server has no rsync; tar over ssh. Existing files are overwritten
  # with identical content, nothing local is deleted.
  ssh "$SERVER" 'tar -C /var/backups -cf - .' | tar -xf - -C "$dest"
  echo "$dest:"; ls -la "$dest"/* | tail -n 5
  exit 0
fi

"${RSYNC[@]}" -a --delete --exclude .git --exclude out --exclude result --exclude "*.log" --exclude "*.qcow2" ./ "$VM_HOST:$VM_DIR/"
# Keep the lock file that nix writes on the VM in the repo.
"${RSYNC[@]}" -a --ignore-missing-args "$VM_HOST:$VM_DIR/flake.lock" ./ 2>/dev/null || true

case "${1:-iso}" in
  eval)
    "${SSH[@]}" "$VM_HOST" "cd $VM_DIR && nix eval .#nixosConfigurations.server.config.system.build.toplevel.drvPath && nix eval .#nixosConfigurations.installer.config.system.build.isoImage.drvPath"
    ;;
  server)
    "${SSH[@]}" "$VM_HOST" "cd $VM_DIR && nix build .#packages.x86_64-linux.server -L --no-link --print-out-paths | xargs nix path-info -Sh"
    ;;
  iso)
    "${SSH[@]}" "$VM_HOST" "cd $VM_DIR && nix build .#packages.x86_64-linux.iso -L --out-link result && ls -lh result/iso/"
    mkdir -p out
    "${RSYNC[@]}" -aL --chmod=u+w "$VM_HOST:$VM_DIR/result/iso/" out/
    ls -lh out/
    ;;
  test)
    "${SSH[@]}" "$VM_HOST" "cd $VM_DIR && nix shell nixpkgs#qemu nixpkgs#expect --command test/qemu-boot-test.sh result/iso/*.iso"
    ;;
  deploy)
    SERVER="${SERVER:?set SERVER=root@<server-ip>}"
    action="${2:-switch}"
    # nixos-rebuild on the dev VM builds the closure (x86_64 via binfmt),
    # copies it to the server with nix copy and activates it there. The
    # server itself never evaluates or builds anything.
    "${SSH[@]}" "$VM_HOST" "bash -s" <<EOF
set -euo pipefail
cd $VM_DIR
export NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new"
nixos-rebuild $action --flake .#server --target-host $SERVER
# Keep /etc/nixos on the server in sync with what was deployed: the same
# files as packages.src, copied straight from the working tree (the nix
# output was found stale once, so no nix in this step).
tar cf - flake.nix flake.lock modules build.sh README.md test |
  ssh -o StrictHostKeyChecking=accept-new $SERVER \
    "rm -rf /etc/nixos && mkdir /etc/nixos && tar xf - -C /etc/nixos"
EOF
    ;;
  *)
    echo "usage: $0 [iso|server|eval|test|deploy|backup]" >&2; exit 2
    ;;
esac
