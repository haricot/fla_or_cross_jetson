#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[[ "$(cat VERSION)" =~ ^2\.0\.0-alpha4-fix1[234567]$ ]]

while IFS= read -r f; do
  bash -n "$f"
done < <(find . -type f \( -name '*.sh' -o -name jetsonctl \) -print | sort)
echo 'shell syntax: PASS'

grep -q "provisioning_schema=.*alpha4-fix12-v1" flash/entrypoint.sh
grep -q '00-fla-hardening.conf' flash/entrypoint.sh
grep -q 'PermitRootLogin no' flash/entrypoint.sh
grep -Fq "grep -Eq '^psk=[0-9a-f]{64}$'" flash/entrypoint.sh
grep -q 'nmcli --offline connection add' flash/entrypoint.sh
grep -q 'SSID Wi-Fi invalide: 1..32 octets requis' flash/entrypoint.sh
grep -q '100005' host/nfs-guard.sh
grep -q 'mount -t nfsd nfsd /proc/fs/nfsd' host/nfs-guard.sh
grep -q 'systemctl restart rpcbind.service' host/nfs-guard.sh
grep -q 'zone=trusted' host/usb-guard.sh
grep -q 'HOST_FLASH_IFACE_INTERVAL:-0.25' flash/network-watch.sh
grep -q 'HOST_FLASH_KEEPALIVE_INTERVAL:-0.5' flash/network-watch.sh
grep -q '192.168.55.100/24' host/post-flash-network.sh
echo 'fix12 static gates: PASS'

want=f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e
have=$(printf '%s' password | python3 -c '
import hashlib,sys
ssid=sys.argv[1].encode("utf-8")
psk=sys.stdin.buffer.read()
sys.stdout.write(hashlib.pbkdf2_hmac("sha1",psk,ssid,4096,32).hex())
' IEEE)
[[ "$have" == "$want" ]]
echo 'Wi-Fi PBKDF2 vector: PASS'
