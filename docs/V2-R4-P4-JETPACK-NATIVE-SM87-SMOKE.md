# V2-R4-P4 — JetPack-native SM87 Link & Device Smoke Test

Branch: `v2-r4-p4-jetpack-native-sm87-smoke`, based on the R4-P3
JetPack 7.2.1 ABI audit. Target: Jetson Orin Nano Super, AArch64, SM87,
JetPack 7.2.1 / Jetson Linux 39.2.1 / Ubuntu 24.04, CUDA 13.2 family.

## Objective

Produce a **JetPack-linked ARM64 host application** that loads a **real SM87
GPU cubin** and verifies an actual SAXPY CUDA kernel on the Jetson later.
Avoid recompiling CUDA code or rebuilding the CUDA environment merely to
repeat an ABI test.

## What the CI builds and reuses

1. Reuse the R4-P2 ARM64 CUDA ELF and verified SM87 fatbin artifact, without
   rebuilding with NVCC:
   https://github.com/haricot/fla_or_cross_jetson/actions/runs/42399023587
2. Reconstruct the **signed Ubuntu noble ARM64 + NVIDIA L4T 39.2.1** thin
   sysroot from R4-P3 using its `--driver-only` subset. This intentionally
   avoids the 484 MB cuBLAS package, which a Driver API smoke test does not
   require. NVIDIA APT packages are **not redistributed**.
3. Obtain `cuobjdump` CUDA 13.2 from NVIDIA's signed x86_64 JetPack host APT
   repository. Extract the actual `sm_87` cubin from the original ELF and
   verify the `_Z5saxpyifPfS_` symbol. This symbol corresponds to the pinned
   upstream Nixpkgs source `saxpy(int,float,float*,float*)`.
4. Obtain NVIDIA's signed `cuda-driver-dev-13-2` ARM64 **link stub**, then
   compile `jetpack_sm87_smoke.c` with Ubuntu's `aarch64-linux-gnu-gcc`.
   The link stub avoids pulling the actual driver's many `NvRm` dependencies
   into this intentionally thin sysroot. At runtime, the genuine JetPack
   `libcuda.so.1` (which is separately checked for API exports) is used.
   The executable must have no Nix interpreter, use AArch64, have
   `DT_NEEDED=libcuda.so.1`, and pass the R4-P3 GLIBC/ELF static ABI gate.
5. Package the two self-built artifacts, a read-only device test script and
   SHA256 manifest into `jetpack-native-sm87-smoke.tar.gz`.

The R4-P2 cubin is independent of the host ELF in R4-P4. We are not
`patchelf`-rewriting an incompatible Nix executable.

## On-device smoke procedure (only after JetPack boots)

No root access or flash is required to run the bundle. Download the R4-P4
GitHub Actions artifact onto the Jetson, then:

```bash
tar -xzf jetpack-native-sm87-smoke.tar.gz
bash run-smoke.sh
```

`run-smoke.sh` checks AArch64 architecture, the `/etc/nv_tegra_release`
Jetson Linux **R39.2.1** marker, and both payload SHA256 hashes before
executing the ARM binary. If a prerequisite is wrong, it fails closed.

The application uses CUDA Driver API to load the SM87 cubin, check target
compute capability **8.7**, allocate two small arrays, launch the kernel
on 1,024 elements and validate:

\[
y_i = 2 x_i + y_i = 4.0,\qquad x_i = 1.0,\ y_i = 2.0.
\]

The acceptance line is `R4_P4_DEVICE_SM87_SAXPY=PASS` with maximum absolute
error at most `1e-5`. The binary also prints the CUDA driver API version and
the actual device compute capability.

## Scope and limits

- GitHub CI **cannot** run this GPU kernel on an actual Jetson Orin Nano.
  `PASS_STATIC_ABI` and a packaged smoke test are not device-runtime PASS.
- No local PC CUDA compile, no local package cleanup, no SSH connection,
  no device flash, no firmware change, and no external device writes.
- The temporary CI environment is not yet persisted as a content-addressed
  CUDA SDK cache. Original R4-P2 and R4-P4 artifacts have finite retention.
- The test runs only after the user confirms an actual JetPack 7.2.1 boot;
  otherwise its guard intentionally rejects execution.
