#!/usr/bin/env bash
# Internal helper library for Smart Host Flash Guard.

SYSFS_ROOT=${SYSFS_ROOT:-/sys}
RECOVERY_USB_PRODUCTS=${RECOVERY_USB_PRODUCTS:-7523,7623}
L4T_GADGET_USB_PRODUCTS=${L4T_GADGET_USB_PRODUCTS-7020}
USB_DEV_ROOT=${USB_DEV_ROOT:-/dev/bus/usb}

# Containers may expose a recovery device via sysfs without its /dev/bus/usb
# character node. Such a phantom must not be accepted as usable for RCM.
usb_devnode_for_sysfs() {
  local sysdev=${1:-} bus dev
  [[ -r "$sysdev/busnum" && -r "$sysdev/devnum" ]] || return 1
  bus=$(cat "$sysdev/busnum")
  dev=$(cat "$sysdev/devnum")
  [[ "$bus" =~ ^[0-9]+$ && "$dev" =~ ^[0-9]+$ ]] || return 1
  printf '%s/%03d/%03d\n' "$USB_DEV_ROOT" "$((10#$bus))" "$((10#$dev))"
}

usb_devnode_available() {
  local node
  node=$(usb_devnode_for_sysfs "$1") || return 1
  [[ -c "$node" ]]
}

recovery_product_list() {
  printf '%s\n' "${RECOVERY_USB_PRODUCTS//,/ }"
}

recovery_product_allowed() {
  local want=${1,,} p
  for p in $(recovery_product_list); do
    [[ "${p,,}" == "$want" ]] && return 0
  done
  return 1
}

l4t_gadget_product_list() {
  printf '%s\n' "${L4T_GADGET_USB_PRODUCTS//,/ }"
}

l4t_gadget_product_allowed() {
  local want=${1,,} p
  for p in $(l4t_gadget_product_list); do
    [[ "${p,,}" == "$want" ]] && return 0
  done
  return 1
}

discover_nvidia_sysfs() {
  local d vendor
  for d in "$SYSFS_ROOT"/bus/usb/devices/*; do
    [[ -r "$d/idVendor" ]] || continue
    [[ "${d##*/}" == *:* ]] && continue
    vendor=$(tr '[:upper:]' '[:lower:]' < "$d/idVendor" 2>/dev/null || true)
    if [[ "$vendor" == 0955 ]]; then
      readlink -f "$d"
      return 0
    fi
  done
  return 1
}

usb_get_udev_attr() {
  local path=$1 attr=$2
  command -v udevadm >/dev/null 2>&1 || return 1
  udevadm info --attribute-walk "$path" 2>/dev/null \
    | sed -n "0,/^[ ]*ATTRS{$attr}==\"\\(.*\\)\"$/s//\\1/p" \
    | head -n1 \
    | xargs
}

usb_ancestor_attr() {
  local path=$1 attr=$2 cur
  cur=$(readlink -f "$path" 2>/dev/null || true)
  while [[ -n "$cur" && "$cur" != / && "$cur" != "$SYSFS_ROOT" ]]; do
    if [[ -r "$cur/$attr" ]]; then
      cat "$cur/$attr"
      return 0
    fi
    cur=${cur%/*}
  done
  return 1
}

discover_recovery_sysfs() {
  local d vendor product
  for d in "$SYSFS_ROOT"/bus/usb/devices/*; do
    [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
    [[ "${d##*/}" == *:* ]] && continue
    vendor=$(tr '[:upper:]' '[:lower:]' < "$d/idVendor" 2>/dev/null || true)
    product=$(tr '[:upper:]' '[:lower:]' < "$d/idProduct" 2>/dev/null || true)
    if [[ "$vendor" == 0955 ]] && recovery_product_allowed "$product"; then
      readlink -f "$d"
      return 0
    fi
  done
  return 1
}

discover_l4t_sysfs() {
  local d vendor product
  for d in "$SYSFS_ROOT"/bus/usb/devices/*; do
    [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
    [[ "${d##*/}" == *:* ]] && continue
    vendor=$(tr '[:upper:]' '[:lower:]' < "$d/idVendor" 2>/dev/null || true)
    product=$(tr '[:upper:]' '[:lower:]' < "$d/idProduct" 2>/dev/null || true)
    if [[ "$vendor" == 0955 ]] && l4t_gadget_product_allowed "$product"; then
      readlink -f "$d"
      return 0
    fi
  done
  return 1
}

discover_iface_for_usb_sysfs() {
  local wanted=${1:-} p iface ancestor
  [[ -n "$wanted" ]] || return 1
  wanted=$(readlink -f "$wanted" 2>/dev/null || true)
  [[ -n "$wanted" ]] || return 1
  for p in "$SYSFS_ROOT"/class/net/*; do
    [[ -e "$p" ]] || continue
    iface=${p##*/}
    [[ "$iface" == lo || "$iface" == docker0 || "$iface" == veth* || "$iface" == br-* ]] && continue
    ancestor=$(usb_device_ancestor "$p" 2>/dev/null || true)
    [[ -n "$ancestor" ]] || continue
    if [[ "$(readlink -f "$ancestor" 2>/dev/null || true)" == "$wanted" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  done
  return 1
}

discover_l4t_iface() {
  local dev
  dev=$(discover_l4t_sysfs 2>/dev/null || true)
  [[ -n "$dev" ]] || return 1
  discover_iface_for_usb_sysfs "$dev"
}

discover_rndis_iface() {
  local forced=${HOST_FLASH_IFACE:-} p iface configuration
  if [[ -n "$forced" && -e "$SYSFS_ROOT/class/net/$forced" ]]; then
    printf '%s\n' "$forced"
    return 0
  fi
  for p in "$SYSFS_ROOT"/class/net/*; do
    [[ -e "$p" ]] || continue
    iface=${p##*/}
    [[ "$iface" == lo || "$iface" == docker0 || "$iface" == veth* || "$iface" == br-* ]] && continue
    configuration=$(usb_get_udev_attr "$p" configuration 2>/dev/null || true)
    [[ -n "$configuration" ]] || configuration=$(usb_ancestor_attr "$p" configuration 2>/dev/null || true)
    if [[ "$configuration" =~ RNDIS\+L4T ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  done
  return 1
}

usb_device_ancestor() {
  local path=$1 cur
  cur=$(readlink -f "$path" 2>/dev/null || true)
  while [[ -n "$cur" && "$cur" != / && "$cur" != "$SYSFS_ROOT" ]]; do
    if [[ -r "$cur/idVendor" && "${cur##*/}" != *:* ]]; then
      printf '%s\n' "$cur"
      return 0
    fi
    cur=${cur%/*}
  done
  return 1
}

usb_path_metadata() {
  local dev=${1:-} cur base emitted_usb=0
  [[ -n "$dev" ]] || dev=$(discover_recovery_sysfs 2>/dev/null || discover_l4t_sysfs 2>/dev/null) || return 1
  cur=$(readlink -f "$dev")
  while [[ -n "$cur" && "$cur" != / && "$cur" != "$SYSFS_ROOT" ]]; do
    base=${cur##*/}
    if [[ -e "$cur/power/control" ]]; then
      if [[ "$base" =~ ^0000:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
        printf 'pci\t%s\t%s\n' "$base" "$cur/power/control"
      elif [[ "$base" =~ ^usb[0-9]+$ ]]; then
        printf 'root-hub\t%s\t%s\n' "$base" "$cur/power/control"
        emitted_usb=1
      elif [[ -r "$cur/idVendor" || "$base" =~ ^[0-9]+-[0-9]+([.][0-9]+)*$ ]]; then
        printf 'usb\t%s\t%s\n' "$base" "$cur/power/control"
        emitted_usb=1
      fi
    fi
    cur=${cur%/*}
  done
  (( emitted_usb == 1 )) || true
}

recovery_summary() {
  local dev nvidia base busnum devnum product product_id serial
  dev=$(discover_recovery_sysfs 2>/dev/null || true)
  nvidia=$(discover_nvidia_sysfs 2>/dev/null || true)
  if [[ -z "$dev" ]]; then
    if [[ -n "$nvidia" ]]; then
      base=${nvidia##*/}
      product_id=$(cat "$nvidia/idProduct" 2>/dev/null || true)
      product=$(cat "$nvidia/product" 2>/dev/null || true)
      echo 'Recovery USB           NOT IN FORCE RECOVERY'
      printf 'USB sysfs              %s\n' "$base"
      [[ -n "$product_id" ]] && printf 'USB VID:PID            0955:%s\n' "$product_id"
      [[ -n "$product" ]] && printf 'USB product            %s\n' "$product"
      if l4t_gadget_product_allowed "$product_id"; then
        printf 'USB mode               L4T gadget (software recovery eligible)\n'
        local l4t_iface
        l4t_iface=$(discover_l4t_iface 2>/dev/null || true)
        [[ -n "$l4t_iface" ]] && printf 'L4T gadget iface       %s\n' "$l4t_iface"
      fi
      printf 'Expected APX PID       %s\n' "$(recovery_product_list | xargs)"
    else
      echo 'Recovery USB           NOT DETECTED'
      printf 'Expected APX PID       %s\n' "$(recovery_product_list | xargs)"
    fi
    return 0
  fi
  base=${dev##*/}
  busnum=$(cat "$dev/busnum" 2>/dev/null || true)
  devnum=$(cat "$dev/devnum" 2>/dev/null || true)
  product_id=$(cat "$dev/idProduct" 2>/dev/null || true)
  product=$(cat "$dev/product" 2>/dev/null || true)
  serial=$(cat "$dev/serial" 2>/dev/null || true)
  echo 'Recovery USB           PASS (APX/RCM)'
  printf 'USB sysfs              %s\n' "$base"
  [[ -n "$product_id" ]] && printf 'USB VID:PID            0955:%s\n' "$product_id"
  [[ -n "$busnum" ]] && printf 'USB bus/device         %s/%s\n' "$busnum" "$devnum"
  [[ -n "$product" ]] && printf 'USB product            %s\n' "$product"
  [[ -n "$serial" ]] && printf 'USB serial             %s\n' "$serial"
  while IFS=$'\t' read -r kind ident control; do
    case "$kind" in
      root-hub) printf 'Root hub              %s (%s)\n' "$ident" "$(cat "$control" 2>/dev/null || echo '?')" ;;
      pci) printf 'PCI controller         %s (%s)\n' "$ident" "$(cat "$control" 2>/dev/null || echo '?')" ;;
    esac
  done < <(usb_path_metadata "$dev" 2>/dev/null || true)
}
