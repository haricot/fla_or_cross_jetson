#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[[ "$(cat VERSION)" == "2.0.0-alpha4-fix17" ]]
./gates/audit-fix16.sh >/dev/null
echo 'fix12..fix16 inheritance: PASS'

bash -n flash/entrypoint.sh

grep -Fq 'SecretSpec' flash/entrypoint.sh
grep -Fq 'if ! IFS= read -r pass < "$passfile"; then' flash/entrypoint.sh
grep -Fq 'if ! IFS= read -r psk < "$DEFAULT_WIFI_PSK_FILE"; then' flash/entrypoint.sh
grep -Fq 'if ! IFS= read -r psk < "$wifi_tmp"; then' flash/entrypoint.sh
grep -Fq 'Fichier mot de passe vide' flash/entrypoint.sh
grep -Fq 'Fichier PSK Wi-Fi vide' flash/entrypoint.sh
grep -Fq 'PSK Wi-Fi déchiffré vide' flash/entrypoint.sh
echo 'fix17 no-newline reader static surface: PASS'

# Reproduce the exact Bash/set -e failure from fix16: a resolver secret file
# containing bytes but no trailing LF makes read return 1 while still filling
# the variable. The guarded pattern must accept it and reject a truly empty file.
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
printf '%s' 'JetsonSecretWithoutLF' > "$t/password"
printf '%s' 'WifiSecretWithoutLF' > "$t/wifi"
: > "$t/empty"

bash -c '
  set -Eeuo pipefail
  pass=""
  if ! IFS= read -r pass < "$1"; then
    [[ -n "$pass" ]] || exit 20
  fi
  [[ "$pass" == JetsonSecretWithoutLF ]]
  psk=""
  if ! IFS= read -r psk < "$2"; then
    [[ -n "$psk" ]] || exit 21
  fi
  [[ "$psk" == WifiSecretWithoutLF ]]
' _ "$t/password" "$t/wifi"
echo 'fix17 no-newline SecretSpec/password+wifi gate: PASS'

if bash -c '
  set -Eeuo pipefail
  pass=""
  if ! IFS= read -r pass < "$1"; then
    [[ -n "$pass" ]] || exit 20
  fi
' _ "$t/empty"; then
  echo 'FAIL: empty secret accepted' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 20 ]]
fi
echo 'fix17 empty-secret rejection gate: PASS'

# Rust resolver must keep writing the exact secret value, with no artificial
# newline; the fix belongs on the shell reader boundary.
grep -Fq 'print!("{}", value.expose_secret());' secret-plane/src/main.rs
! grep -Fq 'println!("{}", value.expose_secret());' secret-plane/src/main.rs
echo 'fix17 exact-byte resolver boundary: PASS'

# Flash reliability inheritance.
grep -Fq '100003' host/nfs-guard.sh
grep -Fq '100005' host/nfs-guard.sh
grep -Fq 'fc00:1:1:0::1/64' host/usb-guard.sh
grep -Fq 'fe80::2/64' host/usb-guard.sh
grep -Fq 'firewall-cmd' host/usb-guard.sh
echo 'NFS/IPv6/firewalld inheritance: PASS'

echo 'fix17 gates: PASS'
