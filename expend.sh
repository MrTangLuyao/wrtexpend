#!/bin/sh
# R3S ImmortalWrt TF-card rootfs expand script (fdisk -> reboot -> losetup+e2fsck+resize2fs -> optional tune2fs)
# This script is designed to be run ONCE. It will schedule stage2 via /etc/rc.local and reboot automatically.

set -eu

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

MARK_DIR="/etc/r3s-expand"
STAGE2="/usr/sbin/r3s-expand-stage2.sh"
RCLOCAL="/etc/rc.local"

log() { echo "[r3s-expand] $*"; }
die() { echo "[r3s-expand][FATAL] $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" = "0" ] || die "must run as root"
}

opkg_install() {
  # $*: packages
  opkg update >/dev/null 2>&1 || true
  opkg install "$@" >/dev/null 2>&1 || opkg install "$@" || die "opkg install failed: $*"
}

resolve_root_dev() {
  # Try /dev/root -> real block device
  ROOT_DEV="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${ROOT_DEV:-}" ] && [ -b "$ROOT_DEV" ]; then
    echo "$ROOT_DEV"
    return
  fi

  # Fallback: mountinfo major:minor for /
  MAJMIN="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  [ -n "${MAJMIN:-}" ] || die "cannot resolve root device (mountinfo)"
  SYS_PATH="$(readlink -f "/sys/dev/block/$MAJMIN" 2>/dev/null || true)"
  [ -n "${SYS_PATH:-}" ] || die "cannot resolve /sys/dev/block/$MAJMIN"
  DEV_NAME="$(basename "$SYS_PATH")"
  [ -n "${DEV_NAME:-}" ] || die "cannot resolve device name"
  ROOT_DEV="/dev/$DEV_NAME"
  [ -b "$ROOT_DEV" ] || die "resolved root dev is not a block device: $ROOT_DEV"
  echo "$ROOT_DEV"
}

split_disk_part() {
  # Input: /dev/mmcblk1p2 or /dev/sda2
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

backup_ptable() {
  disk="$1"
  ts="$(date +%Y%m%d_%H%M%S)"
  out="/root/ptable_backup_${ts}.img"
  log "backing up first 2MiB of $disk to $out"
  dd if="$disk" of="$out" bs=1M count=2 >/dev/null 2>&1 || die "dd backup failed"
}

get_start_sector() {
  disk="$1"
  partdev="$2"

  # fdisk -l output: Device Start End Sectors ...
  start="$(fdisk -l "$disk" 2>/dev/null | awk -v p="$partdev" '$1==p {print $2; exit}')"
  [ -n "${start:-}" ] || die "cannot find start sector for $partdev on $disk"
  echo "$start"
}

ensure_rc_local() {
  if [ ! -f "$RCLOCAL" ]; then
    cat >"$RCLOCAL" <<'EOF'
#!/bin/sh
# Put your custom commands here that should be executed once the system init finished.
# By default this file does nothing.

exit 0
EOF
    chmod +x "$RCLOCAL"
  fi
}

install_stage2_hook() {
  ensure_rc_local

  # Avoid duplicate insertion
  if grep -q "r3s-expand-stage2.sh" "$RCLOCAL" 2>/dev/null; then
    return
  fi

  # Insert before "exit 0" if present, else append.
  if grep -q "^exit 0" "$RCLOCAL"; then
    sed -i 's#^exit 0#'"$STAGE2"' || true\nexit 0#' "$RCLOCAL"
  else
    printf "\n%s\n" "$STAGE2" >>"$RCLOCAL"
  fi
}

remove_stage2_hook() {
  [ -f "$RCLOCAL" ] || return
  sed -i '\#'"$STAGE2"'#d' "$RCLOCAL" 2>/dev/null || true
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

log() { echo "[r3s-expand][stage2] $*"; }
die() { echo "[r3s-expand][stage2][FATAL] $*" >&2; exit 1; }

resolve_root_dev() {
  ROOT_DEV="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${ROOT_DEV:-}" ] && [ -b "$ROOT_DEV" ]; then
    echo "$ROOT_DEV"
    return
  fi
  MAJMIN="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  [ -n "${MAJMIN:-}" ] || die "cannot resolve root device (mountinfo)"
  SYS_PATH="$(readlink -f "/sys/dev/block/$MAJMIN" 2>/dev/null || true)"
  [ -n "${SYS_PATH:-}" ] || die "cannot resolve /sys/dev/block/$MAJMIN"
  DEV_NAME="$(basename "$SYS_PATH")"
  ROOT_DEV="/dev/$DEV_NAME"
  [ -b "$ROOT_DEV" ] || die "resolved root dev is not a block device: $ROOT_DEV"
  echo "$ROOT_DEV"
}

remove_hook() {
  [ -f "$RCLOCAL" ] || return
  sed -i '\#'"$SELF"'#d' "$RCLOCAL" 2>/dev/null || true
}

if [ -f "$MARK_DIR/stage2_done" ]; then
  remove_hook
  exit 0
fi

ROOT_DEV="$(resolve_root_dev)"
log "root device: $ROOT_DEV"

# Sanity: require ext4
if command -v blkid >/dev/null 2>&1; then
  fstype="$(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null || true)"
  [ "${fstype:-}" = "ext4" ] || log "warning: root fs type is '${fstype:-unknown}', continuing anyway"
fi

# Core success path: losetup -> e2fsck -> resize2fs -> detach
command -v losetup >/dev/null 2>&1 || die "losetup not found"
command -v e2fsck  >/dev/null 2>&1 || die "e2fsck not found"
command -v resize2fs >/dev/null 2>&1 || die "resize2fs not found"

LOOP_DEV="$(losetup -f)"
log "using loop device: $LOOP_DEV"

# Map partition to loop
losetup "$LOOP_DEV" "$ROOT_DEV"

# Forced fsck (auto-fix) then resize
e2fsck -f -y "$LOOP_DEV" || true
resize2fs "$LOOP_DEV"

# Detach loop
losetup -d "$LOOP_DEV" || true

# Optional: reduce reserved blocks to 1% if tune2fs exists
if command -v tune2fs >/dev/null 2>&1; then
  tune2fs -m 1 "$ROOT_DEV" || true
fi

sync

touch "$MARK_DIR/stage2_done"
remove_hook

log "done"
exit 0
EOF

  chmod +x "$STAGE2"
}

stage1() {
  mkdir -p "$MARK_DIR"
  [ ! -f "$MARK_DIR/stage1_done" ] || die "stage1 already done; if you need rerun, remove $MARK_DIR/stage1_done"

  # Install required packages (as per successful workflow: fdisk + resize2fs + losetup + e2fsck + optional tune2fs)
  opkg_install fdisk e2fsprogs resize2fs losetup tune2fs blkid || true

  ROOT_DEV="$(resolve_root_dev)"
  log "root device: $ROOT_DEV"

  # Derive disk and partition number
  set -- $(split_disk_part "$ROOT_DEV")
  DISK="$1"
  PARTNUM="$2"
  PARTDEV="$ROOT_DEV"

  log "disk: $DISK  partition: $PARTDEV (num=$PARTNUM)"

  # Backup partition table area
  backup_ptable "$DISK"

  # Get current start sector of root partition
  START_SECTOR="$(get_start_sector "$DISK" "$PARTDEV")"
  log "start sector: $START_SECTOR"

  # Write stage2 script + hook before reboot
  write_stage2
  install_stage2_hook

  # Recreate the same partition number with SAME start sector and default end sector.
  # Critical: when fdisk asks about ext4 signature removal, answer 'n' to keep data.
  log "redefining partition $PARTNUM on $DISK to fill remaining space (will reboot)"
  fdisk "$DISK" <<EOF
d
$PARTNUM
n
p
$PARTNUM
$START_SECTOR

n
w
EOF

  touch "$MARK_DIR/stage1_done"
  sync
  reboot
}

need_root

if [ -f "$MARK_DIR/stage1_done" ] && [ ! -f "$MARK_DIR/stage2_done" ]; then
  log "stage1 already done; stage2 will run automatically on boot via /etc/rc.local"
  exit 0
fi

if [ -f "$MARK_DIR/stage2_done" ]; then
  log "already completed; nothing to do"
  exit 0
fi

stage1
