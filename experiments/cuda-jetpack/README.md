# R4-P1 experimental CUDA cross evaluation

This is a separate Nix flake so it cannot break the **proven Rust-only** `../../flake.nix` build. It pins the *unmerged* `anduril/jetpack-nixos` PR #580 head to `2a4d495b45af809502cb87a757bb12d54f227dbd`.

- `cuda12-6-cross-saxpy`: evaluate the known JetPack 6 / CUDA 12.6 SM87 case to reproduce PR's claim.
- `cuda13-2-cross-saxpy`: evaluate JetPack 7 / CUDA 13.2 SM87, **new unvalidated case**. CUDA 13.3 is not tested here.

CI is **evaluation only** (`nix eval ...drvPath`) to detect Nix cross package splicing failures before any build, GPU test or change to production BSP. A derivation path proves nothing about produced cubin/ELF, linking, or runtime correctness.

To develop locally:

```sh
nix eval --raw ./experiments/cuda-jetpack#packages.x86_64-linux.cuda12-6-cross-saxpy.drvPath
nix eval --raw ./experiments/cuda-jetpack#packages.x86_64-linux.cuda13-2-cross-saxpy.drvPath
```
