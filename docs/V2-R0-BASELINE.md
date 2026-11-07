# V2-R0 — Baseline Recovery / `2.0.0-alpha4-fix17`

Date: 2026-11-07
Repository: `haricot/fla_or_cross_jetson`
Expected branch: `v2-r0-fix17-recovery` (independent of `main`)

## Archive provenance

- `fla_or_cross_jetson_v2.0.0-alpha4-fix17_complete.zip`
- SHA-256: `39ab69a43318be6ecabc01ddfeb0eb6980c66673b0150c39dea5f1f568ba28d1`
- ZIP inspection: 79 entries; no corrupt entry; no path traversal or ZIP symlinks found.
- Source `SHA256SUMS`: all entries verified.

## Evidence observed (local static/synthetic test environment)

| Gate | Result |
| --- | --- |
| SHA-256 archive | PASS |
| All `SHA256SUMS` entries | PASS |
| Bash `-n` (jetsonctl and all .sh) | PASS |
| `gates/audit-fix12.sh` | PASS |
| `gates/audit-fix13.sh` | PASS |
| `gates/audit-fix14.sh` | PASS |
| `gates/audit-fix15.sh` | PASS (Rust compiler step SKIPPED) |
| `gates/audit-fix16.sh` | PASS |
| `gates/audit-fix17.sh` | PASS |
| Rust SecretSpec resolver build | NOT RUN: cargo unavailable |
| Live USB/RCM/Jetson flash | NOT RUN: no target/device access |
| Post-boot CUDA | NOT RUN: no target/device access |

## Fix17 specifics

The `secretspec` resolver prints secret bytes without final LF. Under `set -e`, a plain `IFS= read -r var` returns error at EOF even when the variable was populated. The patch uses `if ! IFS= read -r ...; then [[ -n "$var" ]] || ...; fi` for password and Wi-Fi PSK sources, retaining exact secret bytes and rejecting empty secrets. The synthetic gate confirms no-LF and empty-file behavior.

## Version and reproducibility caveats

- This is the *original, archived fix17 source*. No claim of a successful live hardware flash on fix17.
- `secret-plane/Cargo.toml` pins `secretspec =0.20.0` and `secrecy =0.10.3`, but the archived tree does **not** include a `Cargo.lock`. Reproducible Rust dependency closure should be addressed later without modifying this baseline.
- Later JetPack 7.2.1 / CUDA package compatibility and `jetpack-nixos` additions are expressly outside the recovery commit.
- Never commit private keyrings, passwords, PSKs, real tokens, `$VOLUME`, download caches, or credentials. Source `.env` files under `profiles/` are static profiles and do not constitute actual user credentials.
- The read-only GitHub connector returned `403 Resource not accessible by integration` when attempting to create the recovery branch on 2026-11-07; this report does not imply that source has been pushed.

## Gate to advance into R1

Run in a host environment with Cargo and actual Jetson access (explicitly triggered):

```bash
./gates/audit-fix17.sh
cargo check --manifest-path secret-plane/Cargo.toml
./jetsonctl secrets doctor
```

Proceed to actual flash only when host dependencies, board profile, NFS setup, secrets, and explicit permission to overwrite the target have all been independently verified.
