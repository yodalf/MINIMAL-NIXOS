{
  description = "Minimal NixOS server for Vultr (x86_64, text-only, virtio-only)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # The system that gets installed on the Vultr disk: the generic minimal
      # box plus this machine's role.
      server = lib.nixosSystem {
        inherit system;
        modules = [ ./modules/server.nix ./modules/headscale.nix ];
      };

      # Only these files are copied to /etc/nixos on the installed server (and
      # so into the ISO). Anything else in this directory, such as build logs
      # or disk images, stays out.
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./flake.nix
          ./flake.lock
          ./modules
          ./build.sh
          ./README.md
          ./test
        ];
      };

      # A stripped-down live ISO that carries the prebuilt `server` closure
      # and a `vultr-install` script. Upload it to Vultr as a custom ISO.
      installer = lib.nixosSystem {
        inherit system;
        specialArgs = { inherit src; serverSystem = server.config.system.build.toplevel; };
        modules = [ ./modules/installer.nix ];
      };
    in
    {
      nixosConfigurations = { inherit server installer; };

      packages.${system} = {
        iso = installer.config.system.build.isoImage;
        server = server.config.system.build.toplevel;
        # Same files as `src`, as a derivation so `nix build`/`nix copy` accept it.
        src = nixpkgs.legacyPackages.${system}.runCommandLocal "minimal-nixos-src" { } "cp -r ${src} $out";
        default = installer.config.system.build.isoImage;
      };
    };
}
