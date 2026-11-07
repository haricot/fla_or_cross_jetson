{
  description = "Experimental upstream PR #580 cross-CUDA evaluation for Jetson (no build / no flash)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    jetpack = {
      # Review snapshot: cross NVCC support is NOT merged in upstream master.
      url = "github:anduril/jetpack-nixos/2a4d495b45af809502cb87a757bb12d54f227dbd";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, jetpack, ... }:
    let
      pkgs = import nixpkgs {
        localSystem = "x86_64-linux";
        crossSystem = "aarch64-linux";
        config = {
          allowUnfree = true;
          cudaSupport = true;
          cudaCapabilities = [ "8.7" ];
        };
        overlays = [ jetpack.overlays.default ];
      };
    in
    {
      packages.x86_64-linux.cuda12-6-cross-saxpy = pkgs.cudaPackages_12_6.saxpy;
      # New target: CUDA 13.2 is JetPack 7.x's version family. NOT yet validated by PR #580.
      packages.x86_64-linux.cuda13-2-cross-saxpy = pkgs.cudaPackages_13_2.saxpy;
    };
}
