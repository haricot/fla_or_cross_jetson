# V2-R2/R3/R4 — Upstream-first decision record (2026-11-07)

## Outcome

**Keep `fla_or_cross_jetson` as a cross-build/orchestration project; do not rebuild a Jetson flasher or a CUDA/Nix cross framework from scratch.** R2 and R3 are conditional on upstream compatibility, and R4 starts with a real dependency-free AArch64 Rust build gate.

## Verified upstream capabilities and limitations

| Upstream | Evidence | Plan |
|---|---|---|
| `anduril/jetpack-nixos` | PR #586 merged 2026-10-28; systemd initrd + USB ACM **serial** (not NVMe mass storage). | Reuse initrd, prototype additional NixOS module for NVMe USB export only after firmware and storage review. |
| `anduril/jetpack-nixos` | PR #580 **OPEN** as of 2026-11-07: x86_64 NVCC cross Jetson, tested on CUDA 11.4/12.6, OpenCV, ONNX Runtime and Orin. | Track upstream; do **not** claim CUDA 13.3/13.5 or Thor support without dedicated tests. |
| `AstroRoboticsTech/jetson-flash` | Rust CLI/library Apache-2.0; NVIDIA `l4t_initrd_flash.sh`, Orin Nano Super/AGX Orin validated by maintainers. | Evaluate reuse/dependency before creating another Rust flash CLI. |
| `OE4T/meta-tegra` | Orin/Thor initrd flashing with `--external-only`/`--qspi-only`; different Orin/Thor backends. | Keep as format and transport reference. |
| `ipetkov/crane` | Official `cross-rust-overlay` example; `buildDepsOnly` supports split/cache Cargo compilation. | Use for R4; the initial no-dependency proof has nothing to cache; expand after the basic toolchain passes. |
| NVIDIA CUDA 13.5 | Cross SBSA packages published; `arm64-sbsa-jetson` explicitly Ubuntu 24.04 host per NVIDIA. | Pin distro, host GCC, sysroot, CUDA, target toolkit ABI; avoid accidental x86_64 CUDA/driver linking. |

## R2: generic JetsonFlashBundle contract — DESIGN, NOT IMPLEMENTED

Bundle fields should identify module+carrier+SKU+L4T+boot chain, firmware inventory, partition topology, OS payload, per-file SHA-256 and authentication metadata. Reject mismatches, missing checksums and ambiguous storage selection. Explicit operations: `firmware-only`, `rootfs-only`, `full`, `backup`, `rescue`. Keep NFS as working backend; USB block and Thor as experiments. **No flash operations are added in this branch.**

## R3: NixOS/Ubuntu payloads — DESIGN, NOT IMPLEMENTED

R3 must validate two bootable independent OS payloads with one *compatible* L4T boot/firmware contract. `jetpack-nixos` packages NixOS platform components; Ubuntu remains NVIDIA/Canonical-based. Do not assume an Ubuntu rootfs can boot with arbitrarily selected NixOS kernel/modules. Rootfs checksum and boot ABI checks are mandatory.

## R4: cross Rust/CUDA through Nix — EXECUTION PLAN

1. **R4-P0:** pinned `nixpkgs` (nixos-26.05) + `crane` + `rust-overlay`; produce `aarch64-linux` Rust ELF from x86_64, inspect via `file` and `readelf`. This is the only gate implemented initially.
2. **R4-P1:** test `jetpack-nixos` PR #580 in its own pinned source snapshot on Orin with CUDA **12.6** to reproduce the reported upstream case; do not fork or copy the patch into our main branch.
3. **R4-P2:** move to CUDA **13.3** while holding JetPack 7.2.1 / L4T 39.2.1 fixed; validate nvcc host/target, `cudart`, `libcuda` stubs versus target driver, SM87 cubin/ptx, `readelf` DT_NEEDED and toolchain traces. Compare with existing validated Docker cross.
4. **R4-P3:** `crane` cache layer on a pinned Rust/CUDA sample, then Candle/MistralRS one executable; first runtime gate on Orin Nano Super; finally test SM110 Thor separately.

## Security and determinism

- `flake.lock` is REQUIRED before declaring R4 reproducible. It must be generated with Nix and committed, not guessed.
- No production Secure Boot keys or credentials go into Nix store derivations, logs, OCI images or Git history. Runtime staging only.
- A pass on AArch64 Rust does **not** prove CUDA GPU functionality or a bootable image.
- Retain the existing R1 SDK Manager 26.1, NFS/RPC/IPv6 and SecretSpec paths unchanged until hardware equivalence.

## Links

- https://github.com/anduril/jetpack-nixos/pull/580
- https://github.com/anduril/jetpack-nixos/pull/586
- https://github.com/AstroRoboticsTech/jetson-flash
- https://oe4t.github.io/master/Flashing.html
- https://crane.dev/examples/cross-rust-overlay.html
- https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#cuda-cross-platform-environment
