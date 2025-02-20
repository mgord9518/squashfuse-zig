{
  description = "squashfuse-zig development shell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "i686-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "armv6l-linux"
        "armv7l-linux"
      ];

      pkgs = nixpkgs.legacyPackages;

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {

    packages = forAllSystems (system: {
      default = import ./shell.nix { pkgs = pkgs.${system}; };
    });
  };
}
