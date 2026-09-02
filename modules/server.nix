# Minimal, text-only NixOS server for a Vultr KVM instance.
#
# Everything not needed to boot a virtio VM and serve over SSH is switched
# off. Add services in a separate module or directly below as needed.
{ config, lib, pkgs, modulesPath, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPSVW47bBFslTU+LrvsULGZ/t9RDI5aipdFOD9E8VelA Mac Github"
  ];
in
{
  imports = [
    # Turns off documentation, default packages (perl etc.), xdg, udisks2,
    # logrotate, command-not-found, stub-ld.
    (modulesPath + "/profiles/minimal.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  ### Boot / hardware ########################################################

  # Vultr exposes the disk as virtio-blk (/dev/vda) or, on some plans,
  # virtio-scsi (/dev/sda). Nothing else is needed to find the root fs.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [
    "virtio_net"
    "virtio_balloon"
    "virtio_rng"
    "virtio_console"
  ];
  boot.extraModulePackages = [ ];

  # No firmware blobs at all: a KVM guest has no hardware that needs them.
  hardware.enableRedistributableFirmware = false;
  hardware.enableAllFirmware = false;
  hardware.enableAllHardware = false;
  hardware.firmware = lib.mkForce [ ];

  # Hybrid GRUB: BIOS boot sector on /dev/vda + removable-media EFI binary on
  # the ESP. Works whether Vultr boots the instance in legacy or UEFI mode.
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
    efiSupport = true;
    efiInstallAsRemovable = true;
    configurationLimit = 5;
  };
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.timeout = 2;

  # tty0 is what the Vultr web (VNC) console shows; ttyS0 is the serial one.
  boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ];
  boot.tmp.cleanOnBoot = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = [ "noatime" ];
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };
  swapDevices = [ ];
  zramSwap.enable = true;

  ### Networking #############################################################

  networking.hostName = "server";
  networking.useNetworkd = true;
  networking.useDHCP = true;
  networking.firewall.enable = true;
  systemd.network.wait-online.enable = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Lets the Vultr panel do clean shutdowns/reboots and query the guest.
  services.qemuGuest.enable = true;

  ### Users ##################################################################

  users.mutableUsers = false;
  users.users.root.openssh.authorizedKeys.keys = sshKeys;
  users.users.realo = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
    # Console (VNC) login only; SSH password auth is off. Change with
    # `openssl passwd -6` and rebuild.
    hashedPassword = "$6$M7HeexihuQ0AAx58$bED5gFkYVgxfKIJrtK5N0itOLa8Ywbs44fA9qc9xxYw3CIzHqec9itvbRdDqRsL0w28Qn6Biop2KeKwbJe/Kt/";
  };
  security.sudo.wheelNeedsPassword = false;

  ### Size trimming ##########################################################

  # Do not copy the nixpkgs source tree into the closure. `nixos-rebuild
  # --flake` fetches the pinned nixpkgs from the lock file instead.
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;

  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;
  fonts.fontconfig.enable = false;
  services.lvm.enable = false;
  boot.enableContainers = false;
  programs.nano.enable = false;

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" ];
  time.timeZone = "UTC";

  services.journald.extraConfig = ''
    SystemMaxUse=200M
  '';

  ### Nix ####################################################################

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    trusted-users = [ "root" "@wheel" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  environment.systemPackages = with pkgs; [
    gitMinimal # to pull this repo on the server
    vim
  ];
}
