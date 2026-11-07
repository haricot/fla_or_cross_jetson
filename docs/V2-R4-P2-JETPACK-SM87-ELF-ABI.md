# V2-R4-P2 — JetPack CUDA ABI, SM87 fatbin and deployability gate

Branch: `v2-r4-p2-cuda133-sm87-audit`, based on R4-P1
(`v2-r4-p1-cuda-default-probe`). No physical Jetson was modified.

## Correct target and immutable dependencies

- Target: Jetson Orin Nano Super, Ampere SM87, AArch64.
- NVIDIA **JetPack 7.2.1 / L4T 39.2.1** ships **CUDA 13.2.2**, Ubuntu
  24.04, Linux 6.8. NVIDIA source:
  https://developer.nvidia.com/embedded/jetpack/downloads
- Our Nixpkgs input remains pinned to
  `NixOS/nixpkgs@c56a87d8e41ce69bd2af57eb35dcc117a9dfca33`;
  jetpack-nixos cross patches remain pinned to
  `anduril/jetpack-nixos@2a4d495b45af809502cb87a757bb12d54f227dbd`.
- The Nix CUDA 13.2 package set is `13.2.0`, not the same patchlevel as
  JetPack's `13.2.2`. This is **not** a validated drop-in compatibility claim.

## CUDA 13.3 forward-compatibility diagnostic

The pinned Nixpkgs **defines** `cudaPackages_13_3` (version 13.3.0) but
rejects evaluating its AArch64 SAXPY derivation because
`cuda13.3-cuda_cccl-0-unsupported` has an empty `meta.platforms` and
`aarch64-linux` in `meta.badPlatforms`.
Do **not** bypass this with `allowUnsupportedSystem` or mix 13.2/13.3 CUDA
components to mask the failure. CUDA 13.3 is **not** the bundled JetPack
7.2.1 CUDA version, either.

The 13.3 derivation is retained as a *diagnostic only*. The CI logs the
rejection and tests actual GPU code with JetPack-aligned CUDA 13.2 instead.

## Cross-build and ELF audit

R4-P1 already proved AArch64 compile+link with default CUDA 13.2:
https://github.com/haricot/fla_or_cross_jetson/actions/runs/42398040976

R4-P2 CI:
https://github.com/haricot/fla_or_cross_jetson/actions/workflows/v2-r4-p2-cuda133-sm87-audit.yml

The job checks all of these independently:

1. **AArch64**: `file` + `readelf -h` verify ARM AArch64 ELF.
2. **Actual SM87 cubin**: x86 host `cuobjdump --list-elf` reads the cross
   compiled executable's embedded CUDA ELF and must list `sm_87`.
   This does **not** infer capability merely from the CMake architecture flag.
3. **Optional PTX**: `cuobjdump --list-ptx`; no PTX is required when the
   verified `sm_87` cubin is present.
4. **ABI evidence**: `readelf -l`, `readelf -d`, and
   `readelf --version-info` are retained.
5. **Deployability classification**: an interpreter underneath
   `/nix/store` explicitly produces `JETPACK_DEPLOY=BLOCKED_NIX_ELF_INTERPRETER`,
   independently of build/GPU-code success.
6. **Reuse**: the small AArch64 sample ELF and all audit text files are
   archived as one CI artifact for 14 days, avoiding another build for
   later static inspection.

## Non-goals and mandatory next gate

**Do not copy the Nix-built ELF directly to JetPack Ubuntu.**
The R4-P1 ELF had a `/nix/store/...glibc-2.42.../ld-linux-aarch64.so.1`
interpreter; JetPack 7.2.1 uses Ubuntu 24.04 with glibc 2.39.
Changing only the interpreter with `patchelf` does **not** establish ABI
compatibility: GLIBC symbol requirements, CUDA libraries, runtime paths,
and driver interface must all be validated.

R4-P3 should build against a **pinned JetPack 7.2.1 AArch64 sysroot**
or a verified compatible deployment closure and then check:

- absolute ELF interpreter existing on JetPack;
- no unbundled `/nix/store` dependencies;
- `DT_NEEDED` libraries resolvable in target image;
- maximum required GLIBC symbol version no newer than available on target;
- CUDA 13.2 runtime/driver ABI;
- **real** Orin Nano Super launch only after the machine is ready.

No local GPU compilation, storage erasure, firmware update, flashing,
user-credential access, or deployment is performed by R4-P2.
