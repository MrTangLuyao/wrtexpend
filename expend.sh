#!/bin/sh
# ImmortalWrt/OpenWrt ext4 rootfs expand on TF-card / eMMC
# Stage1: extend ROOT partition (same partition number) to end-of-disk using sfdisk (no fdisk signature prompt)
#         (handles sfdisk dump formats where ":" is separated as field2)
# Stage2 (after reboot): losetup + e2fsck + resize2fs to grow ext4, optional tune2fs -m 1, then cleanup.
#
# Usage:
#   wget -O /tmp/expend.sh <RAW_URL> && sh /tmp/expend.sh
#
# Notes:
# - Works for /dev/mmcblkXpY and /dev/sdXY style names.
# - Does NOT rely on parsing start= from sfdisk output; uses sysfs start sector.
# - Does NOT require partprobe/partx; just reboots after rewriting partition table.

set -eu
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

MARK_DIR="/etc/r3s-expand"
STAGE2="/usr/sbin/r3s-expand-stage2.sh"
RCLOCAL="/etc/rc.local"

log(){ echo "[expand] $*"; }
die(){ echo "[expand][FATAL] $*" >&2; exit 1; }

need_root(){ [ "$(id -u)" = "0" ] || die "must run as root"; }

opkg_try_install() {
  # best-effort only; opkg may be noisy if *.list was deleted
  opkg update >/dev/null 2>&1 || true
  opkg install "$@" >/dev/null 2>&1 || opkg install "$@" || true
}

resolve_root_dev() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  majmin="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  [ -n "${majmin:-}" ] || die "cannot resolve root device (mountinfo)"
  sys="$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)"
  [ -n "${sys:-}" ] || die "cannot resolve sysfs block path"
  dev="/dev/$(basename "$sys")"
  [ -b "$dev" ] || die "resolved root dev is not block device: $dev"
  echo "$dev"
}

split_disk_part() {
  dev="$1"
  case "$dev" in
    /dev/mmcblk*p[0-9]*)
      disk="${dev%p*}"
      partnum="${dev##*p}"
      ;;
    /dev/*[0-9])
      disk="$(echo "$dev" | sed -E 's/[0-9]+$//')"
      partnum="$(echo "$dev" | sed -E 's/^.*[^0-9]([0-9]+)$/\1/')"
      ;;
    *)
      die "unsupported root device name: $dev"
      ;;
  esac
  [ -b "$disk" ] || die "disk is not a block device: $disk"
  echo "$disk $partnum"
}

ensure_rc_local() {
  if [ ! -f "$RCLOCAL" ]; then
    cat >"$RCLOCAL" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RCLOCAL"
  fi
}

install_stage2_hook() {
  ensure_rc_local
  grep -q "$STAGE2" "$RCLOCAL" 2>/dev/null && return 0
  if grep -q "^exit 0" "$RCLOCAL"; then
    sed -i "s#^exit 0#$STAGE2 || true\nexit 0#" "$RCLOCAL"
  else
    printf "\n%s || true\n" "$STAGE2" >>"$RCLOCAL"
  fi
}

remove_stage2_hook() {
  [ -f "$RCLOCAL" ] || return 0
  sed -i "\#$STAGE2#d" "$RCLOCAL" 2>/dev/null || true
}

write_stage2() {
  mkdir -p "$MARK_DIR"
  cat >"$STAGE2" <<'EOF'
#!/bin/sh
set -eu
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

MARK_DIR="/etc/r3s-expand"
RCLOCAL="/etc/rc.local"
SELF="/usr/sbin/r3s-expand-stage2.sh"

log(){ echo "[expand][stage2] $*"; }

resolve_root_dev() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  majmin="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  sys="$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)"
  echo "/dev/$(basename "$sys")"
}

# Idempotent
if [ -f "$MARK_DIR/stage2_done" ]; then
  [ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
  exit 0
fi

ROOT_DEV="$(resolve_root_dev)"
log "root device: $ROOT_DEV"

command -v losetup >/dev/null 2>&1 || exit 1
command -v e2fsck  >/dev/null 2>&1 || exit 1
command -v resize2fs >/dev/null 2>&1 || exit 1

LOOP_DEV="$(losetup -f)"
log "using loop: $LOOP_DEV"

losetup "$LOOP_DEV" "$ROOT_DEV"
e2fsck -f -y "$LOOP_DEV" || true
resize2fs "$LOOP_DEV"
losetup -d "$LOOP_DEV" || true

command -v tune2fs >/dev/null 2>&1 && tune2fs -m 1 "$ROOT_DEV" || true

sync
touch "$MARK_DIR/stage2_done"

[ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
exit 0
EOF
  chmod +x "$STAGE2"
}

backup_ptable() {
  disk="$1"
  ts="$(date +%Y%m%d_%H%M%S)"
  out="/root/ptable_backup_${ts}.img"
  dd if="$disk" of="$out" bs=1M count=2 >/dev/null 2>&1 || true
  log "ptable backup: $out"
}

get_start_sector_sysfs() {
  part="$1"   # /dev/mmcblk1p2
  disk="$2"   # /dev/mmcblk1

  bpart="$(basename "$part")"
  bdisk="$(basename "$disk")"

  for f in \
    "/sys/class/block/$bpart/start" \
    "/sys/block/$bdisk/$bpart/start"
  do
    if [ -r "$f" ]; then
      cat "$f"
      return 0
    fi
  done
  return 1
}

calc_and_apply_sfdisk() {
  disk="$1"
  part="$2"

  command -v blockdev >/dev/null 2>&1 || die "blockdev not found"
  command -v sfdisk   >/dev/null 2>&1 || die "sfdisk not found"

  start="$(get_start_sector_sysfs "$part" "$disk" || true)"
  [ -n "${start:-}" ] || die "cannot read start sector from sysfs for $part"

  total="$(blockdev --getsz "$disk")"
  [ -n "${total:-}" ] || die "cannot get disk total sectors"
  newsize=$(( total - start ))
  [ "$newsize" -gt 0 ] || die "computed new size invalid"

  log "start=$start total=$total new_size=$newsize"

  dump="/tmp/pt.sfdisk"
  new="/tmp/pt.new.sfdisk"
  sfdisk -d "$disk" >"$dump"

  # Robust match: handles both "/dev/mmcblk1p2:" and "/dev/mmcblk1p2 :" (colon as separate field)
  awk -v p="$part" -v ns="$newsize" '
    (($1==p && $2==":") || ($1==p":")) {
      sub(/size=[0-9]+/, "size="ns)
    }
    {print}
  ' "$dump" >"$new"

  # Safety: ensure replacement actually happened
  if ! grep -qE "^${part}(:|[[:space:]]+:)[[:space:]].*size=${newsize}([,[:space:]]|$)" "$new"; then
    die "failed to rewrite size= for $part (dump format unexpected)"
  fi

  sfdisk --no-reread --force "$disk" <"$new"
}

stage1() {
  mkdir -p "$MARK_DIR"

  # If stage1 already done, do not rewrite partition table again; stage2 will run on next boot.
  if [ -f "$MARK_DIR/stage1_done" ]; then
    log "stage1 already done; reboot to let stage2 run if needed"
    exit 0
  fi

  ROOT_DEV="$(resolve_root_dev)"
  log "root device: $ROOT_DEV"

  set -- $(split_disk_part "$ROOT_DEV")
  DISK="$1"
  PARTNUM="$2"
  log "disk: $DISK  partnum: $PARTNUM"

  backup_ptable "$DISK"
  calc_and_apply_sfdisk "$DISK" "$ROOT_DEV"

  touch "$MARK_DIR/stage1_done"
  sync
  log "partition table updated; rebooting to reload table; stage2 will run on boot"
  reboot
}

main() {
  need_root

  if [ -f "$MARK_DIR/stage2_done" ]; then
    log "already completed; nothing to do"
    exit 0
  fi

  # Ensure required tools exist (best-effort)
  opkg_try_install sfdisk losetup resize2fs e2fsprogs tune2fs blockdev

  write_stage2
  install_stage2_hook

  stage1
}

main
