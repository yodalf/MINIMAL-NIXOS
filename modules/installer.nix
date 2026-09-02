# Live ISO used only to install `server` onto a Vultr instance.
#
# Deliberately NOT based on installation-cd-minimal.nix: that pulls in
# all-hardware, every filesystem, firmware blobs, the manual and a copy of
# nixpkgs. This ISO has just enough to partition /dev/vda and copy the
# prebuilt server closure onto it, with no network required.
{ config, lib, pkgs, modulesPath, self, serverSystem, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPSVW47bBFslTU+LrvsULGZ/t9RDI5aipdFOD9E8VelA Mac Github"
  ];

  vultr-install = pkgs.writeShellApplication {
    name = "vultr-install";
    runtimeInputs = with pkgs; [ gptfdisk dosfstools e2fsprogs util-linux coreutils config.system.build.nixos-install ];
    text = ''
      DISK="''${1:-/dev/vda}"
      if [ ! -b "$DISK" ]; then
        echo "no such block device: $DISK" >&2
        echo "usage: vultr-install [/dev/vda]" >&2
        exit 1
      fi

      echo "This will ERASE $DISK and install NixOS 'server' on it."
      read -r -p "Type YES to continue: " answer
      [ "$answer" = "YES" ] || exit 1

      # GPT: 1M BIOS-boot (legacy GRUB), 256M ESP (UEFI GRUB), rest ext4 root.
      sgdisk --zap-all "$DISK"
      sgdisk \
        -n1:0:+1M   -t1:EF02 -c1:bios \
        -n2:0:+256M -t2:EF00 -c2:ESP \
        -n3:0:0     -t3:8300 -c3:nixos \
        "$DISK"
      partprobe "$DISK" || true
      udevadm settle

      mkfs.vfat -F32 -n ESP /dev/disk/by-partlabel/ESP
      mkfs.ext4 -F -L nixos /dev/disk/by-partlabel/nixos
      udevadm settle

      mount /dev/disk/by-label/nixos /mnt
      mkdir -p /mnt/boot
      mount /dev/disk/by-label/ESP /mnt/boot

      # The closure is already in this ISO's store, so this is a copy plus
      # a GRUB install; nothing is downloaded or built.
      nixos-install --root /mnt --system ${serverSystem} --no-root-passwd --no-channel-copy

      # Ship the flake so the server can `nixos-rebuild switch --flake /etc/nixos#server`.
      mkdir -p /mnt/etc/nixos
      cp -rT ${self} /mnt/etc/nixos
      chmod -R u+w /mnt/etc/nixos

      sync
      echo
      echo "Done. Detach the ISO in the Vultr panel, then: reboot"
    '';
  };
in
{
  imports = [
    (modulesPath + "/installer/cd-dvd/iso-image.nix")
    (modulesPath + "/profiles/minimal.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  isoImage = {
    edition = "vultr-installer";
    makeBiosBootable = true;
    makeEfiBootable = true;
    makeUsbBootable = true;
    # Carry the server closure and this repo in the ISO's nix store.
    storeContents = [ serverSystem self ];
    squashfsCompression = "zstd -Xcompression-level 19";
  };

  # The ISO's own filesystems are the squashfs overlay, not the host layout.
  fileSystems = lib.mkImageMediaOverride config.lib.isoFileSystems;
  swapDevices = lib.mkImageMediaOverride [ ];

  # QEMU/KVM: the ISO may be attached as IDE/SATA/SCSI cdrom depending on the
  # Vultr plan, hence a slightly broader set than the installed server.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
    "ahci"
    "ata_piix"
  ];
  boot.kernelModules = [ "virtio_net" "virtio_rng" "virtio_console" ];
  boot.supportedFilesystems = [ "ext4" "vfat" ];
  boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ];

  hardware.enableRedistributableFirmware = false;
  hardware.enableAllFirmware = false;
  hardware.enableAllHardware = false;
  hardware.firmware = lib.mkForce [ ];

  networking.hostName = "installer";
  networking.useNetworkd = true;
  networking.useDHCP = true;
  systemd.network.wait-online.enable = false;

  # Auto-login root on the console; SSH with the same keys as the server.
  users.users.root.initialHashedPassword = "";
  users.users.root.openssh.authorizedKeys.keys = sshKeys;
  services.getty.autologinUser = "root";
  services.getty.helpLine = ''

    Run `vultr-install` to install NixOS on /dev/vda.
  '';
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
    settings.PasswordAuthentication = false;
  };

  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;
  documentation.enable = false;
  fonts.fontconfig.enable = false;
  services.lvm.enable = false;
  boot.enableContainers = false;
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = [ vultr-install ];
}
