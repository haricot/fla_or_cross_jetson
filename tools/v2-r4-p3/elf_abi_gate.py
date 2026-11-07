#!/usr/bin/env python3
"""Read-only AArch64 ELF / JetPack sysroot ABI gate.

Never executes the target program and never patches its ELF interpreter.
The gate distinguishes a valid cross-built binary from a deployable binary.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path

GLIBC_RE = re.compile(r"\bGLIBC_(\d+)\.(\d+)\b")
NEEDED_RE = re.compile(r"\(NEEDED\).*Shared library:\s*\[([^]]+)\]")
RPATH_RE = re.compile(r"\((RPATH|RUNPATH)\).*Library (?:rpath|runpath):\s*\[([^]]*)\]")
INTERP_RE = re.compile(r"Requesting program interpreter:\s*([^]]+)\]")


def readelf(*args: str) -> str:
    return subprocess.check_output(["readelf", *args], text=True, stderr=subprocess.STDOUT)


def glibc_versions(text: str) -> list[tuple[int, int]]:
    return sorted({(int(m.group(1)), int(m.group(2))) for m in GLIBC_RE.finditer(text)})


def version_text(version: tuple[int, int] | None) -> str | None:
    return ".".join(map(str, version)) if version else None


def find_lib(sysroot: Path, name: str) -> Path | None:
    # This tests presence in a sysroot, not dynamic loader search-path resolution.
    # No symlink is followed outside the sysroot. ELF RPATH is checked separately.
    for root, dirs, files in os.walk(sysroot, followlinks=False):
        dirs[:] = [d for d in dirs if d not in {"proc", "sys", "dev"}]
        if name not in files and name not in dirs:
            continue
        path = Path(root) / name
        if not path.is_symlink() and path.is_file():
            return path.relative_to(sysroot)
        if path.is_symlink():
            dest = os.readlink(path)
            # Absolute symlinks inside a rootfs must resolve against the rootfs,
            # not against the CI runner's /.
            candidate = (
                sysroot / dest.lstrip("/")
                if dest.startswith("/")
                else path.parent / dest
            )
            normalized = Path(os.path.normpath(candidate))
            if normalized.is_relative_to(sysroot) and normalized.exists():
                return path.relative_to(sysroot)
    return None


def audit(binary: Path, sysroot: Path, required_libs: list[str]) -> dict:
    header = readelf("-h", str(binary))
    segments = readelf("-l", str(binary))
    dynamic = readelf("-d", str(binary))
    versions = readelf("--version-info", str(binary))

    arch_aarch64 = bool(re.search(r"Machine:\s*AArch64", header))
    match = INTERP_RE.search(segments)
    interpreter = match.group(1).strip() if match else None
    needed = sorted(set(NEEDED_RE.findall(dynamic)))
    runtime_paths = [dict(kind=k, value=v) for k, v in RPATH_RE.findall(dynamic)]
    required = sorted(set(needed) | set(required_libs))
    present = {name: find_lib(sysroot, name) for name in required}

    # libc.so.6 contains the GLIBC symbol definitions in Ubuntu/NVIDIA rootfs.
    libc = find_lib(sysroot, "libc.so.6")
    sysroot_max_glibc = None
    if libc:
        libc_path = sysroot / libc
        # readelf follows ordinary symlinks. For absolute rootfs symlinks,
        # search for the actual library file under the same package directory.
        try:
            sysroot_versions = glibc_versions(readelf("--version-info", str(libc_path)))
            sysroot_max_glibc = max(sysroot_versions) if sysroot_versions else None
        except subprocess.CalledProcessError:
            pass

    required_versions = glibc_versions(versions)
    max_required = max(required_versions) if required_versions else None
    reasons: list[str] = []
    if not arch_aarch64:
        reasons.append("NOT_AARCH64")
    if not interpreter:
        reasons.append("NO_ELF_INTERPRETER")
    elif interpreter.startswith("/nix/store/"):
        reasons.append("NIX_STORE_INTERPRETER")
    elif not (sysroot / interpreter.lstrip("/")).exists():
        reasons.append("INTERPRETER_ABSENT_FROM_SYSROOT")
    if any("/nix/store/" in entry["value"] for entry in runtime_paths):
        reasons.append("NIX_STORE_RPATH")
    for lib_name, lib_path in present.items():
        if lib_path is None:
            reasons.append("LIBRARY_MISSING:" + lib_name)
    if sysroot_max_glibc is None:
        reasons.append("SYSROOT_GLIBC_NOT_DETECTED")
    elif max_required and max_required > sysroot_max_glibc:
        reasons.append("GLIBC_SYMBOL_TOO_NEW")

    return {
        "status": "PASS_STATIC_ABI" if not reasons else "BLOCKED_STATIC_ABI",
        "reasons": sorted(set(reasons)),
        "note": "Static inspection only; passing does not prove runtime execution on Jetson",
        "binary": str(binary),
        "sysroot": str(sysroot),
        "elf_aarch64": arch_aarch64,
        "elf_interpreter": interpreter,
        "needed": needed,
        "runtime_paths": runtime_paths,
        "required_libraries_present": {
            name: str(path) if path is not None else None for name, path in sorted(present.items())
        },
        "required_glibc_max": version_text(max_required),
        "sysroot_glibc_max": version_text(sysroot_max_glibc),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--sysroot", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--require-lib", action="append", default=[])
    parser.add_argument("--expect", choices=["pass", "blocked"], required=True)
    args = parser.parse_args()

    if not args.binary.is_file() or not args.sysroot.is_dir():
        parser.error("--binary must be a file and --sysroot must be a directory")
    result = audit(args.binary, args.sysroot.resolve(), args.require_lib)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    print("R4_P3_ABI=" + result["status"] + " reasons=" + ",".join(result["reasons"]))
    wants_pass = args.expect == "pass"
    return 0 if (result["status"] == "PASS_STATIC_ABI") == wants_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
