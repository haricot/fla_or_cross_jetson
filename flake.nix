{
  description = "V2-R4: experimental x86_64 -> aarch64 Rust cross-build for Jetson";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    crane.url = "github:ipetkov/crane/v0.21.0";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, crane, rust-overlay, ... }:
    let
      # Cross build platform is always x86_64; the Jetson runs aarch64 Linux.
      pkgs = import nixpkgs {
        localSystem = "x86_64-linux";
        crossSystem = "aarch64-linux";
        overlays = [ (import rust-overlay) ];
      };
      craneLib = (crane.mkLib pkgs).overrideToolchain (p: p.rust-bin.stable.latest.default);
      crossProof = pkgs.callPackage ({ }: craneLib.buildPackage {
        src = craneLib.cleanCargoSource ./nix/cross-proof;
        strictDeps = true;
        doCheck = false; # cross AArch64 binaries cannot execute on the x86_64 builder
      }) { };
    in
    {
      packages.x86_64-linux.cross-rust-aarch64 = crossProof;
      packages.x86_64-linux.default = crossProof;
      checks.x86_64-linux.cross-rust-aarch64 = crossProof;
    };
}
