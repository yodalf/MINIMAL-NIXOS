# Minimal, text-only NixOS server for a Vultr KVM instance.
#
# Everything not needed to boot a virtio VM and serve over SSH is switched
# off. Add services in a separate module or directly below as needed.
{ config, lib, pkgs, modulesPath, ... }:

let
  # Minimal stand-in for `nixos-rebuild switch|boot --flake /etc/nixos#server`.
  rebuild = pkgs.writeShellApplication {
    name = "rebuild";
    runtimeInputs = [ config.nix.package ];
    text = ''
      action="''${1:-switch}"
      flake="''${2:-/etc/nixos#server}"
      case "$action" in
        switch|boot|test|dry-activate) ;;
        *) echo "usage: rebuild [switch|boot|test|dry-activate] [flake#name]" >&2; exit 2 ;;
      esac
      [ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
      out=$(nix build --no-link --print-out-paths \
              "''${flake%%#*}#nixosConfigurations.''${flake##*#}.config.system.build.toplevel")
      if [ "$action" != test ] && [ "$action" != dry-activate ]; then
        nix-env -p /nix/var/nix/profiles/system --set "$out"
      fi
      exec "$out/bin/switch-to-configuration" "$action"
    '';
  };

  sshKeys = [
    # Mac
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPSVW47bBFslTU+LrvsULGZ/t9RDI5aipdFOD9E8VelA Mac Github"
    # NixOS dev VM (realix), used by `build.sh deploy`
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDL0KSdYf8ksk61rXqXVhg1n8ZEOJYLetnSDxUO+Jhi5CxTvJDX9gDuQ2NDTKEA5drf53uMT7deGCGVCL9L++3hpXabQ1CQrpptIzxad9ZskIYgbwG0cahfeYlUp7q9SzyPG4rNYdW3tb5ijP3fvg0PkhkrmEGjoYlu/x7/6tCWdRioWLGxvnVT6CIyU6iVjMJzc3bX0nVkv6Hat541U2GEGq1uRhM4Um5D75ki1yWpqbAr5cqH+A/JtTrPUC7iVThBZvu+QLrKH6fxFHQVVSS3sdEz3K73MaLUph7m290cNxYhYBP1/wcaH4aQvKzLCuJbM2gIG/jy4RUTAd01UyTKb/raBcMyQ7GkS6iVpwELpQSHN2e+dBngXoIB6GLDl2vo7aVf+6AqI7WcCKpbnff547aTotdM0DsK8OVrQ3xZdxOnghgZXKPRn6ge9BksKFeBM1mcYyEDZ+4zUN8oWxUMV6CINFnMSFrPs0wk7W4Xxkv7/SQcQz7q/jhd1bHgFyU= realo"
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

  # Kernel messages go to both consoles. The last console= is the primary one
  # (/dev/console), where systemd prints its status lines and any emergency
  # shell appears: the serial port, as cloud images do. tty0 is what the
  # Vultr web (VNC) console shows.
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
  boot.consoleLogLevel = 7;
  boot.initrd.verbose = true;
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

  networking.hostName = lib.mkDefault "server";
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

  # No QEMU guest agent: Vultr's panel stop/restart are ACPI events that
  # systemd already handles. Enabling it would add qemu-ga + glib (~20 MB).
  services.qemuGuest.enable = false;

  ### Users ##################################################################

  users.mutableUsers = false;
  users.users.root.openssh.authorizedKeys.keys = sshKeys;
  users.users.realo = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
    # No password: access is SSH-key only (sudo needs no password). To allow
    # console (VNC) login, add hashedPassword = "<output of openssl passwd -6>".
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

  # systemd-importd drags in gnupg + openldap; nothing here imports images.
  systemd.services.systemd-importd.enable = false;

  # Installer tools: nixos-rebuild is a Python program in 26.05 (+127 MB),
  # nixos-option pulls man-db/groff, the others are only useful on the ISO.
  # `rebuild` below does what `nixos-rebuild switch --flake` does in ~5 lines.
  system.tools.nixos-rebuild.enable = false;
  system.tools.nixos-option.enable = false;
  system.tools.nixos-generate-config.enable = false;
  system.tools.nixos-install.enable = false;
  system.tools.nixos-enter.enable = false;

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
    rebuild
  ];
}
