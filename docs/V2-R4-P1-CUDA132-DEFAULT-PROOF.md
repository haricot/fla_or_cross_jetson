# R4-P1 — CUDA 13.2 default package set: AArch64 cross-build proof

Status: **PASS_BUILD_LINK** (2026-11-07); runtime and deployability **NOT YET PROVEN**.

## Baseline and root cause

Baseline: `v2-r234-nix-cross-foundation` at `d1ff3ebd282178a74b842a5f345cc27d30f8d46c`.

- Rust AArch64 cross proof: PASS (existing R4-P0, unchanged).
- CUDA 12.6/13.2 Nix derivation evaluations: PASS.
- Original CUDA 13.2 SAXPY build: FAIL at CMake 4.1.6. It printed
  `The CUDA compiler identification is unknown` and then
  `_CMAKE_CUDA_WHOLE_FLAG` was missing.
- CUDA 12.6 build: cancelled at the previous CI job's 25-minute timeout,
  so no binary proof.

Upstream `anduril/jetpack-nixos` PR #580 (pinned at
`2a4d495b45af809502cb87a757bb12d54f227dbd`) notes that
cross-compilation of non-default versioned CUDA package sets is unsupported
by the current Nixpkgs CUDA module splicing behavior.

## Isolated change

The experimental `experiments/cuda-jetpack/flake.nix` retains both original
targets and adds a cross Nixpkgs instance with
`cudaPackages = prev.cudaPackages_13_2`, exposing
`cuda13-2-default-cross-saxpy`. CUDA 12.6 has an equivalent control.

Evaluation CI: https://github.com/haricot/fla_or_cross_jetson/actions/runs/42397929122

- All four derivations evaluated.
- CUDA 12.6 default and versioned derivation paths matched.
- CUDA 13.2 default and versioned derivation paths differed.

Real cross-build CI: https://github.com/haricot/fla_or_cross_jetson/actions/runs/42398040976

- `nvcc` invoked on the x86_64 builder with an AArch64 cross host C++ compiler.
- CMake CUDA configuration, compilation and linking: PASS.
- `file`: `ELF 64-bit LSB pie executable, ARM aarch64`.
- `readelf -h`: machine AArch64.
- Nix CUDA architecture setting: `CMAKE_CUDA_ARCHITECTURES=87`.

## Reproduce (non-destructive)

From the experimental branch:

```bash
nix eval --raw './experiments/cuda-jetpack#packages.x86_64-linux.cuda13-2-default-cross-saxpy.drvPath'
nix build -L './experiments/cuda-jetpack#cuda13-2-default-cross-saxpy'
file result/bin/saxpy
readelf -h result/bin/saxpy
```

The `#` flake syntax is quoted for zsh compatibility. The build can
download a large Nix dependency closure. Prefer CI if host disk space is tight.

## Explicitly NOT validated

1. `cuobjdump` verification that the ELF contains `sm_87` cubin and/or
   `compute_87` PTX (the CMake architecture flag alone is not proof).
2. Runtime on the Jetson Orin Nano Super GPU and JetPack 7.2.1/L4T 39.2.1.
3. CUDA 13.3 runtime/SDK ABI compatibility (this experiment selects CUDA 13.2).
4. A self-contained JetPack-deployable ELF. Its ELF interpreter is still a
   Nix store path
   `/nix/store/...-glibc-aarch64-unknown-linux-gnu-2.42-103/lib/ld-linux-aarch64.so.1`;
   do not copy it directly to Ubuntu and expect it to run.
5. Flash/reflash, firmware, storage, user credentials, and NVMe content.

Next: verify GPU code and DT_NEEDED/RPATH without rebuilding when possible,
then plan the JetPack-compatible sysroot/runtime packaging gate. Keep all
flash operations explicitly separate from cross-build tests.
