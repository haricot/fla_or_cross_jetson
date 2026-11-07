#!/usr/bin/env bash
# Non-destructive R2/R3/R4 foundation checks. This is not a Jetson flash gate.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# Keep original fix17 and R1 cumulative checks intact.
./gates/audit-r1.sh >/dev/null

test -s flake.nix
test -s nix/cross-proof/Cargo.toml
test -s nix/cross-proof/Cargo.lock
test -s nix/cross-proof/src/main.rs

grep -Fq 'github:NixOS/nixpkgs/nixos-26.05' flake.nix
grep -Fq 'github:ipetkov/crane/v0.21.0' flake.nix
grep -Fq 'crossSystem = "aarch64-linux"' flake.nix
grep -Fq 'checks.x86_64-linux.cross-rust-aarch64' flake.nix
grep -Fq 'aarch64' nix/cross-proof/src/main.rs
test -s docs/V2-R234-UPSTREAM-DECISION.md

python3 - <<'PY'
import pathlib, tomllib
root = pathlib.Path('.')
t = tomllib.loads((root/'nix/cross-proof/Cargo.toml').read_text())
lock = tomllib.loads((root/'nix/cross-proof/Cargo.lock').read_text())
assert t['package']['name'] == 'jetson-cross-proof'
assert any(p['name'] == t['package']['name'] for p in lock['package'])
PY

echo 'R2/R3 documented, R4 Nix/Rust cross skeleton: PASS (static only)'
