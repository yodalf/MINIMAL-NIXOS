#!/usr/bin/env bash
#
# End-to-end test of the installer ISO in QEMU (x86_64, TCG so it works on any
# host): boot the ISO, run `vultr-install` on a virtio disk, reboot from that
# disk and log in over the serial console. Prints PASS/FAIL.
#
#   test/qemu-boot-test.sh result/iso/nixos-vultr-*.iso
#
# Needs qemu and expect; run via `nix shell nixpkgs#qemu nixpkgs#expect`.
set -euo pipefail

ISO="${1:?usage: $0 <iso>}"
WORK="${WORK:-$(mktemp -d)}"
DISK="$WORK/disk.qcow2"
PASSWORD="${CONSOLE_PASSWORD:?set CONSOLE_PASSWORD (the server has none by default; add hashedPassword to test console login)}"
QEMU="${QEMU:-qemu-system-x86_64}"

qemu-img create -q -f qcow2 "$DISK" 8G
echo "work dir: $WORK"

common=(-m 2048 -smp 2 -nographic -no-reboot
        -drive "file=$DISK,if=virtio,format=qcow2"
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0)

echo "### phase 1: boot ISO and install"
expect -f - "$QEMU" "${common[@]}" -cdrom "$ISO" -boot d <<'EXP'
set timeout 2400
spawn {*}$argv
expect {
    -re {root@installer:~\]#} {}
    timeout { puts "FAIL: no root shell on installer"; exit 1 }
    eof     { puts "FAIL: qemu exited during ISO boot"; exit 1 }
}
send "vultr-install\r"
expect {
    "Type YES to continue:" {}
    timeout { puts "FAIL: vultr-install did not prompt"; exit 1 }
}
send "YES\r"
expect {
    "Done. Detach the ISO" {}
    -re {(error|Error|FAIL)} { puts "FAIL: install error"; exit 1 }
    timeout { puts "FAIL: install timed out"; exit 1 }
    eof     { puts "FAIL: qemu exited during install"; exit 1 }
}
send "poweroff\r"
expect eof
EXP

echo "### phase 2: boot installed disk and log in"
expect -f - "$QEMU" "${common[@]}" -boot c "$PASSWORD" <<'EXP'
set timeout 900
set password [lindex $argv end]
spawn {*}[lrange $argv 0 end-1]
expect {
    "server login:" {}
    timeout { puts "FAIL: no login prompt from installed system"; exit 1 }
    eof     { puts "FAIL: qemu exited during disk boot"; exit 1 }
}
send "realo\r"
expect "Password:"
send "$password\r"
expect {
    -re {realo@server:~\]\$} {}
    timeout { puts "FAIL: login failed"; exit 1 }
}
send "sudo systemctl is-system-running; sudo ls /nix/var/nix/profiles/ /etc/nixos; df -h / /boot; echo BOOT-TEST-OK\r"
expect {
    "BOOT-TEST-OK" {}
    timeout { puts "FAIL: shell command failed"; exit 1 }
}
send "sudo poweroff\r"
expect eof
puts "PASS"
EXP
