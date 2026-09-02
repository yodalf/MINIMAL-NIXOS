{
  description = "Minimal NixOS server for Vultr (x86_64, text-only, virtio-only)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # The system that gets installed on the Vultr disk.
      server = lib.nixosSystem {
        inherit system;
        modules = [ ./modules/server.nix ];
      };

      # A stripped-down live ISO that carries the prebuilt `server` closure
      # and a `vultr-install` script. Upload it to Vultr as a custom ISO.
      installer = lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self; serverSystem = server.config.system.build.toplevel; };
        modules = [ ./modules/installer.nix ];
      };
    in
    {
      nixosConfigurations = { inherit server installer; };

      packages.${system} = {
        iso = installer.config.system.build.isoImage;
        server = server.config.system.build.toplevel;
        default = installer.config.system.build.isoImage;
      };
    };
}
