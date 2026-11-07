# V2-R4-P3 — JetPack 7.2.1 signed AArch64 sysroot and runtime ABI

Branch: `v2-r4-p3-jetpack721-sysroot-abi` (based on R4-P2).

Target: **Jetson Orin Nano Super / SM87 / AArch64**, NVIDIA
**JetPack 7.2.1 / L4T 39.2.1 / Ubuntu 24.04 / CUDA 13.2.2**.
Source: https://developer.nvidia.com/embedded/jetpack/downloads

## Why R4-P2 is not deployable

R4-P2 compiled a real SM87 cubin into an AArch64 ELF and archived it:
https://github.com/haricot/fla_or_cross_jetson/actions/runs/42399023587

That successful cross-build uses a Nix glibc 2.42 interpreter and Nix-store
`RPATH`. Copying that ELF to a stock Ubuntu 24.04 JetPack installation would
not be a valid deployment. Rewriting just its ELF interpreter is not a
substitute for a proper target ABI link.

## Reconstructed ABI reference, not a flashed rootfs

`tools/v2-r4-p3/prepare_thin_sysroot.sh` downloads **signed** ARM64 APT
packages from Ubuntu noble and NVIDIA `common r39.2` + `som r39.2` using an
**isolated** APT configuration. The NVIDIA key is local to the job. It extracts
`.deb` files with `dpkg-deb --extract`; it installs nothing on the CI host or
user workstation.

Ubuntu noble uses a merged-`/usr` filesystem. Because a thin extraction does
not contain Ubuntu's `base-files` layout, the script recreates the ordinary
`/lib` → `/usr/lib` alias **inside the temporary sysroot only** and checks
that the actual `/lib/ld-linux-aarch64.so.1` is then accessible. It does not
invent a loader binary or modify an ELF interpreter.

The exact downloaded version and SHA256 of each package is recorded in
`package-manifest.tsv`; the verified key fingerprint and APT policy are also
retained. A 600 MiB total-download safety budget avoids accidentally pulling
the complete CUDA SDK. The sysroot is kept only in the disposable CI job:
**NVIDIA binary packages are not republished in the public build artifact.**

| ABI package | Verified snapshot (2026-11-07) | Purpose |
| --- | --- | --- |
| `libc6` | `2.39-0ubuntu8.9` | Target glibc and loader |
| `libgcc-s1` | `14.2.0-4ubuntu2~24.04.1` | GCC runtime |
| `libstdc++6` | `14.2.0-4ubuntu2~24.04.1` | C++ runtime |
| `cuda-cudart-13-2` | `13.2.86-1` | CUDA runtime 13 ABI |
| `libcublas-13-2` | `13.4.1.3-1` | cuBLAS + cuBLASLt ABI |
| `nvidia-l4t-cuda` | `39.2.1-20260806224157` | L4T CUDA integration |
| `nvidia-l4t-cuda-nvgpu` | `39.2.1-20260806224157` | L4T GPU driver libraries |

**Important:** cuBLAS has independent component versioning. Its
`13.4.1.3-1` package version does **not** mean this JetPack uses CUDA 13.4;
the package `libcublas-13-2` comes from NVIDIA's signed r39.2 repository.

## Fail-closed static ELF ABI gate

`tools/v2-r4-p3/elf_abi_gate.py` never executes or patches the ARM binary.
It reports:

- ELF architecture and absolute interpreter;
- `DT_NEEDED`, `RPATH`/`RUNPATH`, and the presence of expected target libs;
- max required GLIBC symbol version against glibc in the signed sysroot;
- why an ELF is blocked (`NIX_STORE_INTERPRETER`, `NIX_STORE_RPATH`, etc.).

The reused R4-P2 ELF is expected to return `BLOCKED_STATIC_ABI`. Once all
required CUDA shared objects were included, the expected remaining reasons
were **only** `NIX_STORE_INTERPRETER` and `NIX_STORE_RPATH`:
https://github.com/haricot/fla_or_cross_jetson/actions/runs/42401205864

## Independent Ubuntu AArch64 CUDA 13 link probe

`jetpack_abi_probe.c` exercises the tiny stable CUDA Runtime C ABI
`cudaRuntimeGetVersion`. The GitHub runner builds the probe with Ubuntu's
`aarch64-linux-gnu-gcc` and links to NVIDIA's extracted
`libcudart.so.13`. Unlike the pre-existing Nix ELF, this must satisfy the
same static ELF gate in `--expect pass` mode. It does **not** contain an SM87
kernel; R4-P2 already supplies independent physical SM87 cubin evidence.

The probe is *not run* in CI. Passing the link and static symbol checks does
not demonstrate a working CUDA driver, GPU kernel execution, device power
mode, thermals, or performance on the Jetson.

## Scope and next gate

- No local GPU compile or heavyweight CUDA SDK deployment on the user's PC.
- No SSH, firmware update, JetPack flash, startup of target services, or
  claim of verified Jetson runtime execution.
- The thin sysroot is not an entire Jetson root filesystem; transitive
  loader resolution for arbitrary applications is **not** proved.
- **R4-P4** should rebuild the real SM87 sample against the JetPack-compatible
  target toolchain/ABI and, after the physical Jetson is configured, perform
  a bounded real-device smoke test. Do not promote on static evidence alone.

The manifests and probes are intended to make a future content-addressed
reuse cache possible. The current CI **rebuilds the thin sysroot** when
triggered; it does not yet provide a persistent environment cache.
