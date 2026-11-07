#!/usr/bin/env bash
set -Eeuo pipefail

EXPORTS_FILE=${NFS_EXPORTS_FILE:-/etc/exports.d/fla-or-cross-jetson.exports}
STATE_FILE=""
L4T_DIR=""
CMD=""

usage() {
  cat <<'USAGE'
usage: sudo nfs-guard.sh --state FILE --l4t-dir DIR <begin|status|restore>
USAGE
}

while (($#)); do
  case "$1" in
    --state) STATE_FILE=${2:-}; shift 2 ;;
    --l4t-dir) L4T_DIR=${2:-}; shift 2 ;;
    begin|status|restore) CMD=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "option inconnue: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ ${EUID} -eq 0 ]] || { echo "nfs-guard doit être exécuté en root." >&2; exit 1; }
[[ -n "$STATE_FILE" ]] || { echo "--state requis" >&2; exit 2; }
[[ -n "$L4T_DIR" ]] || { echo "--l4t-dir requis" >&2; exit 2; }
[[ -n "$CMD" ]] || { usage >&2; exit 2; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 absent sur l'hôte." >&2; exit 1; }; }
need exportfs
need showmount
need rpcinfo

BACKUP="${STATE_FILE}.nfs-exports.bak"
HAD_FILE="${STATE_FILE}.nfs-had-file"
SERVICE_STATE="${STATE_FILE}.nfs-services.tsv"
NFSD_MOUNT_STATE="${STATE_FILE}.nfsd-mounted"

required_paths() {
  printf '%s\n' \
    "$L4T_DIR/tools/kernel_flash/tmp" \
    "$L4T_DIR/tools/kernel_flash/images" \
    "$L4T_DIR/rootfs"
}

systemd_unit_exists() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local state
  state=$(systemctl show -p LoadState --value "$1" 2>/dev/null || true)
  [[ -n "$state" && "$state" != "not-found" ]]
}

nfs_server_unit() {
  if systemd_unit_exists nfs-server.service; then
    printf '%s\n' nfs-server.service
  elif systemd_unit_exists nfs-kernel-server.service; then
    printf '%s\n' nfs-kernel-server.service
  else
    return 1
  fi
}

snapshot_services() {
  : > "$SERVICE_STATE"
  local unit active
  for unit in rpcbind.service "$(nfs_server_unit 2>/dev/null || true)"; do
    [[ -n "$unit" ]] || continue
    active=0
    systemctl is-active --quiet "$unit" 2>/dev/null && active=1 || true
    printf '%s\t%s\n' "$unit" "$active" >> "$SERVICE_STATE"
  done
  if mountpoint -q /proc/fs/nfsd 2>/dev/null; then printf '1\n' > "$NFSD_MOUNT_STATE"; else printf '0\n' > "$NFSD_MOUNT_STATE"; fi
}

start_stack() {
  local nfs_unit=""
  mkdir -p /run/rpcbind /proc/fs/nfsd
  mountpoint -q /proc/fs/nfsd 2>/dev/null || mount -t nfsd nfsd /proc/fs/nfsd

  if command -v systemctl >/dev/null 2>&1; then
    nfs_unit=$(nfs_server_unit 2>/dev/null || true)
    [[ -n "$nfs_unit" ]] || { echo 'Aucun service nfs-server/nfs-kernel-server disponible.' >&2; return 1; }
    # Real R39.2.1 hardware validation showed that merely "start" was not
    # sufficient on the host: mountd was absent until the RPC/NFS stack was
    # restarted. Restart is intentional; enablement is never changed.
    systemctl restart rpcbind.service
    systemctl restart "$nfs_unit"
  else
    pgrep -x rpcbind >/dev/null 2>&1 || rpcbind -w
    if command -v rpc.nfsd >/dev/null 2>&1; then
      rpc.nfsd 8 || true
    fi
    if command -v rpc.mountd >/dev/null 2>&1 && ! pgrep -x rpc.mountd >/dev/null 2>&1; then
      rpc.mountd || true
    fi
  fi

  exportfs -rav
  command -v rpc.nfsd >/dev/null 2>&1 && rpc.nfsd 8 >/dev/null 2>&1 || true
}

verify_rpc() {
  local rpc missing=0
  rpc=$(rpcinfo -p localhost 2>/dev/null || true)
  if awk '$1==100000 {found=1} END{exit !found}' <<<"$rpc"; then echo 'Host RPC portmapper: PASS'; else echo 'Host RPC portmapper: FAIL' >&2; missing=1; fi
  if awk '$1==100003 {found=1} END{exit !found}' <<<"$rpc"; then echo 'Host NFS rpc 100003: PASS'; else echo 'Host NFS rpc 100003: FAIL' >&2; missing=1; fi
  if awk '$1==100005 {found=1} END{exit !found}' <<<"$rpc"; then echo 'Host mountd rpc 100005: PASS'; else echo 'Host mountd rpc 100005: FAIL' >&2; missing=1; fi
  return "$missing"
}

verify_exports() {
  local out p missing=0
  out=$(showmount -e localhost 2>/dev/null || true)
  while IFS= read -r p; do
    if awk 'NR > 1 {print $1}' <<<"$out" | grep -Fxq -- "$p"; then
      echo "Host NFS export: PASS ($p)"
    else
      echo "Host NFS export: FAIL ($p)" >&2
      missing=1
    fi
  done < <(required_paths)
  if grep -q '/sdk_manager/downloads/Linux_for_Tegra' <<<"$out"; then
    echo 'Host NFS export: NOTE stale sdk_manager export(s) also present; left untouched.'
  fi
  return "$missing"
}

verify() {
  local rc=0
  mountpoint -q /proc/fs/nfsd 2>/dev/null && echo 'Host nfsd fs: PASS (/proc/fs/nfsd)' || { echo 'Host nfsd fs: FAIL' >&2; rc=1; }
  verify_rpc || rc=1
  verify_exports || rc=1
  return "$rc"
}

restore_services() {
  [[ -r "$SERVICE_STATE" ]] || return 0
  local unit was_active
  while IFS=$'\t' read -r unit was_active; do
    [[ -n "$unit" ]] || continue
    if [[ "$was_active" == 0 ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
  done < <(tac "$SERVICE_STATE" 2>/dev/null || cat "$SERVICE_STATE")

  if [[ -r "$NFSD_MOUNT_STATE" && "$(cat "$NFSD_MOUNT_STATE")" == 0 ]]; then
    # Only undo our mount after services which did not previously exist as
    # active have been stopped. If still busy, leave it mounted rather than
    # disrupting another NFS consumer.
    umount /proc/fs/nfsd >/dev/null 2>&1 || true
  fi
}

case "$CMD" in
  status)
    verify
    ;;
  begin)
    mkdir -p "$(dirname "$STATE_FILE")" /etc/exports.d \
      "$L4T_DIR/tools/kernel_flash/tmp" \
      "$L4T_DIR/tools/kernel_flash/images" \
      "$L4T_DIR/rootfs"
    chmod 0755 "$L4T_DIR/tools/kernel_flash/tmp" "$L4T_DIR/tools/kernel_flash/images" "$L4T_DIR/rootfs" || true
    chown root:root "$L4T_DIR/tools/kernel_flash/tmp" "$L4T_DIR/tools/kernel_flash/images" "$L4T_DIR/rootfs" || true

    snapshot_services
    if [[ -e "$EXPORTS_FILE" ]]; then
      cp -a "$EXPORTS_FILE" "$BACKUP"
      printf '1\n' > "$HAD_FILE"
    else
      rm -f "$BACKUP"
      printf '0\n' > "$HAD_FILE"
    fi
    cat > "$EXPORTS_FILE" <<EOT
$L4T_DIR/tools/kernel_flash/tmp *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
$L4T_DIR/tools/kernel_flash/images *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
$L4T_DIR/rootfs *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
EOT
    chmod 0644 "$EXPORTS_FILE"
    start_stack
    verify
    ;;
  restore)
    if [[ -r "$HAD_FILE" ]] && [[ $(cat "$HAD_FILE") == 1 ]] && [[ -r "$BACKUP" ]]; then
      cp -a "$BACKUP" "$EXPORTS_FILE"
    else
      rm -f "$EXPORTS_FILE"
    fi
    exportfs -ra >/dev/null 2>&1 || true
    restore_services
    rm -f "$BACKUP" "$HAD_FILE" "$SERVICE_STATE" "$NFSD_MOUNT_STATE"
    echo 'Host NFS Guard: RESTORED'
    ;;
esac
