#!/usr/bin/env bash
#
# Sync this repo to the NixOS dev VM and build the Vultr installer ISO there
# (the ISO is x86_64; the VM builds it via binfmt emulation).
#
#   ./build.sh            build the ISO, copy it to ./out/
#   ./build.sh server     only build the server closure and print its size
#   ./build.sh eval       just evaluate (fast syntax/option check)
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
"${RSYNC[@]}" -a --delete --exclude .git --exclude out --exclude result ./ "$VM_HOST:$VM_DIR/"
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
    "${RSYNC[@]}" -aL "$VM_HOST:$VM_DIR/result/iso/" out/
    ls -lh out/
    ;;
  *)
    echo "usage: $0 [iso|server|eval]" >&2; exit 2
    ;;
esac
