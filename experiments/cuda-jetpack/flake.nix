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
      mkCrossPkgs = extraOverlays: import nixpkgs {
        localSystem = "x86_64-linux";
        crossSystem = "aarch64-linux";
        config = {
          allowUnfree = true;
          cudaSupport = true;
          cudaCapabilities = [ "8.7" ];
        };
        overlays = [ jetpack.overlays.default ] ++ extraOverlays;
      };
      pkgs = mkCrossPkgs [];
      # PR #580: a versioned CUDA set must also be the default when cross-building.
      withDefaultCuda = versionedAttr: mkCrossPkgs [
        (final: prev: { cudaPackages = builtins.getAttr versionedAttr prev; })
      ];
      cuda126Pkgs = withDefaultCuda "cudaPackages_12_6";
      cuda132Pkgs = withDefaultCuda "cudaPackages_13_2";
      # Separate forward-compatibility probe. JetPack 7.2.1 itself ships CUDA 13.2.2.
      cuda133Pkgs = withDefaultCuda "cudaPackages_13_3";
      hostCuda132 = import nixpkgs {
        localSystem = "x86_64-linux";
        config.allowUnfree = true;
        overlays = [ (final: prev: { cudaPackages = prev.cudaPackages_13_2; }) ];
      };
    in
    {
      packages.x86_64-linux.cuda12-6-cross-saxpy = pkgs.cudaPackages_12_6.saxpy;
      # New target: CUDA 13.2 is JetPack 7.x's version family. NOT yet validated by PR #580.
      packages.x86_64-linux.cuda13-2-cross-saxpy = pkgs.cudaPackages_13_2.saxpy;
      # Isolated diagnostic targets; preserve existing baseline derivations.
      packages.x86_64-linux.cuda12-6-default-cross-saxpy = cuda126Pkgs.cudaPackages.saxpy;
      packages.x86_64-linux.cuda13-2-default-cross-saxpy = cuda132Pkgs.cudaPackages.saxpy;
      # R4-P2: genuine CUDA 13.3 cross compiler and host-side fatbin inspector.
      packages.x86_64-linux.cuda13-3-default-cross-saxpy = cuda133Pkgs.cudaPackages.saxpy;
      # Use the JetPack-aligned 13.2 inspector for the proven CUDA 13.2 binary.
      packages.x86_64-linux.cuda13-2-host-cuobjdump = hostCuda132.cudaPackages.cuda_cuobjdump;
    };
}
