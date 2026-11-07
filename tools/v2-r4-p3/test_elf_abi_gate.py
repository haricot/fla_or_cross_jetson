#!/usr/bin/env python3
"""Unit tests for the static ABI inspector (no Jetson required)."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

module_path = Path(__file__).with_name("elf_abi_gate.py")
spec = importlib.util.spec_from_file_location("elf_abi_gate", module_path)
assert spec is not None and spec.loader is not None
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ElfGateTest(unittest.TestCase):
    def test_glibc_version_numeric_sort(self) -> None:
        sample = "Name: GLIBC_2.17 Name: GLIBC_2.39 Name: GLIBC_2.9 Name: GLIBC_PRIVATE"
        self.assertEqual(max(gate.glibc_versions(sample)), (2, 39))

    def test_needed_and_rpath_parsing(self) -> None:
        dynamic = (
            " 0x00000001 (NEEDED) Shared library: [libc.so.6]\n"
            " 0x0000001d (RUNPATH) Library runpath: [/nix/store/abc/lib]\n"
        )
        self.assertEqual(gate.NEEDED_RE.findall(dynamic), ["libc.so.6"])
        self.assertEqual(gate.RPATH_RE.findall(dynamic), [("RUNPATH", "/nix/store/abc/lib")])

    def test_absolute_link_does_not_escape_sysroot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "usr/lib/aarch64-linux-gnu"
            folder.mkdir(parents=True)
            (folder / "libc.so.6").symlink_to("/etc/passwd")
            self.assertIsNone(gate.find_lib(root, "libc.so.6"))

    def test_relative_link_within_sysroot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "usr/lib/aarch64-linux-gnu"
            folder.mkdir(parents=True)
            (folder / "libc.so.6.real").write_bytes(b"not-executable")
            (folder / "libc.so.6").symlink_to("libc.so.6.real")
            self.assertEqual(gate.find_lib(root, "libc.so.6"), Path("usr/lib/aarch64-linux-gnu/libc.so.6"))


if __name__ == "__main__":
    unittest.main()
