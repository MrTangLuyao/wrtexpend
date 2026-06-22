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
  # OpenWrt/ImmortalWrt 25.x uses apk; older releases use opkg.
  if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
  else
    die "neither apk nor opkg was found"
  fi
  log "package manager: $PKG_MANAGER"
}
pkg_update() {
  case "$PKG_MANAGER" in
    apk) apk update >/dev/null 2>&1 || true ;;
    opkg) opkg update >/dev/null 2>&1 || true ;;
  esac
}
pkg_try_install() {
  case "$PKG_MANAGER" in
    apk) apk add "$@" >/dev/null 2>&1 || apk add "$@" || true ;;
    opkg) opkg install "$@" >/dev/null 2>&1 || opkg install "$@" || true ;;
  esac
}
ensure_tool() {
  tool="$1"
  shift
  command -v "$tool" >/dev/null 2>&1 && return 0
  for package in "$@"; do
    pkg_try_install "$package"
    command -v "$tool" >/dev/null 2>&1 && return 0
  done
  die "required command not found after package installation: $tool"
}
install_dependencies() {
  pkg_update
  # Package names changed with the apk-based OpenWrt/ImmortalWrt 25.x feeds.
  # Try the current split packages first, then the old package names.
  ensure_tool sfdisk    util-linux-sfdisk sfdisk
  ensure_tool losetup   util-linux-losetup losetup
  ensure_tool e2fsck    e2fsprogs-e2fsck e2fsprogs
  ensure_tool resize2fs e2fsprogs-resize2fs resize2fs e2fsprogs
  ensure_tool tune2fs   e2fsprogs-tune2fs tune2fs e2fsprogs
}
resolve_root_dev() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  # On current OpenWrt/ImmortalWrt, / is often overlayfs (major:minor 0:*).
  # Its writable backing Ext4 partition is mounted at /overlay.
  dev="$(awk '$2=="/overlay" {print $1; exit}' /proc/mounts 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  majmin="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  [ -n "${majmin:-}" ] || die "cannot resolve root device (mountinfo)"
  sys="$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)"
  [ -n "${sys:-}" ] || die "cannot resolve root device; / is overlayfs and /overlay is not a block device"
  dev="/dev/$(basename "$sys")"
  [ -b "$dev" ] || die "cannot resolve root device; / is overlayfs and /overlay is not a block device"
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
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
MARK_DIR="/etc/r3s-expand"
RCLOCAL="/etc/rc.local"
SELF="/usr/sbin/r3s-expand-stage2.sh"
log(){ echo "[expand][stage2] $*"; }
resolve_root_dev() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  dev="$(awk '$2=="/overlay" {print $1; exit}' /proc/mounts 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  majmin="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  sys="$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)"
  [ -n "${sys:-}" ] || exit 1
  dev="/dev/$(basename "$sys")"
  [ -b "$dev" ] || exit 1
  echo "$dev"
}
if [ -f "$MARK_DIR/stage2_done" ]; then
  [ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
  exit 0
fi
ROOT_DEV="$(resolve_root_dev)"
log "root device: $ROOT_DEV"
command -v losetup >/dev/null 2>&1 || exit 1
command -v e2fsck  >/dev/null 2>&1 || exit 1
command -v resize2fs >/dev/null 2>&1 || exit 1
command -v tune2fs >/dev/null 2>&1 || exit 1
LOOP_DEV="$(losetup -f)"
log "using loop: $LOOP_DEV"
losetup "$LOOP_DEV" "$ROOT_DEV"
e2fsck -f -y "$LOOP_DEV" || true
resize2fs "$LOOP_DEV"
losetup -d "$LOOP_DEV" || true
tune2fs -m 1 "$ROOT_DEV" 2>/dev/null || true
sync
touch "$MARK_DIR/stage2_done"
[ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
sync
reboot
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
  ROOT_DEV="$(resolve_root_dev)"
  log "root device: $ROOT_DEV"
  set -- $(split_disk_part "$ROOT_DEV")
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
  install_dependencies
  write_stage2
  install_stage2_hook
  stage1_expand_partition_only
  touch "$MARK_DIR/stage1_done" 2>/dev/null || true
  sync
  log "stage1 done; rebooting (stage2 will run automatically on boot)"
  reboot
}
main
