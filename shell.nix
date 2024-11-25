{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs.buildPackages; [
    zig_0_13

    # Required for building test SquashFS images
    squashfsTools

    lz4
  ];
}
