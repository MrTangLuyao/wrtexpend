#!/bin/sh
set -eu
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
MARK_DIR="/etc/r3s-expand"
STAGE2="/usr/sbin/r3s-expand-stage2.sh"
RCLOCAL="/etc/rc.local"
log(){ echo "[expand] $*"; }
die(){ echo "[expand][FATAL] $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" = "0" ] || die "must run as root"; }
PKG_MANAGER=""
detect_package_manager() {
  if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
  else
    die "neither apk nor opkg was found"
  fi
  log "package manager: $PKG_MANAGER"
}
pkg_try_install() {
  case "$PKG_MANAGER" in
    apk)
      apk update >/dev/null 2>&1 || true
      apk add "$@" >/dev/null 2>&1 || apk add "$@" || true
      ;;
    opkg)
      opkg update >/dev/null 2>&1 || true
      opkg install "$@" >/dev/null 2>&1 || opkg install "$@" || true
      ;;
  esac
}
overlay_device() {
  awk '$2=="/overlay" {print $1; exit}' /proc/mounts 2>/dev/null || true
}
loop_backing_partition() {
  loop="$1"
  backing="$(cat "/sys/class/block/${loop##*/}/loop/backing_file" 2>/dev/null || true)"
  case "$backing" in
    /dev/*) dev="$backing" ;;
    /*) dev="/dev$backing" ;;
    *) die "cannot resolve loop backing device for $loop" ;;
  esac
  [ -b "$dev" ] || die "loop backing device is not a block device: $dev"
  echo "$dev"
}
resolve_root_partition() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  dev="$(overlay_device)"
  case "$dev" in
    /dev/loop*) loop_backing_partition "$dev"; return ;;
  esac
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
resolve_filesystem_device() {
  dev="$(overlay_device)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  resolve_root_partition
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
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
MARK_DIR="/etc/r3s-expand"
RCLOCAL="/etc/rc.local"
SELF="/usr/sbin/r3s-expand-stage2.sh"
log(){ echo "[expand][stage2] $*"; }
filesystem_device() {
  dev="$(awk '$2=="/overlay" {print $1; exit}' /proc/mounts 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  [ -n "${dev:-}" ] && [ -b "$dev" ] || return 1
  echo "$dev"
}
if [ -f "$MARK_DIR/stage2_done" ]; then
  [ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
  exit 0
fi
FS_DEV="$(filesystem_device)" || exit 1
log "filesystem device: $FS_DEV"
command -v resize2fs >/dev/null 2>&1 || exit 1
case "$FS_DEV" in
  /dev/loop*)
    command -v losetup >/dev/null 2>&1 || exit 1
    # The partition grew during stage 1; refresh the existing loop device.
    losetup -c "$FS_DEV"
    ;;
esac
resize2fs "$FS_DEV"
sync
touch "$MARK_DIR/stage2_done"
[ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
sync
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
stage1_expand_partition_only() {
  ROOT_PART="$(resolve_root_partition)"
  log "root partition: $ROOT_PART"
  set -- $(split_disk_part "$ROOT_PART")
  DISK="$1"
  PARTNUM="$2"
  log "disk: $DISK  partnum: $PARTNUM"
  command -v sfdisk >/dev/null 2>&1 || die "sfdisk not found"
  command -v fdisk  >/dev/null 2>&1 || true
  backup_ptable "$DISK"
  log "expanding partition $PARTNUM on $DISK to fill remaining space"
  sfdisk --force -N "$PARTNUM" "$DISK" <<EOF
, +
EOF
  sync
}
main() {
  need_root
  detect_package_manager
  rm -f "$MARK_DIR/stage2_done" "$MARK_DIR/stage1_done" 2>/dev/null || true
  remove_stage2_hook || true
  pkg_try_install sfdisk losetup resize2fs
  stage1_expand_partition_only
  write_stage2
  install_stage2_hook
  touch "$MARK_DIR/stage1_done" 2>/dev/null || true
  sync
  log "stage1 done; rebooting (stage2 will run automatically on boot)"
  reboot
}
main
