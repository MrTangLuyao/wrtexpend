#!/bin/sh
set -eu

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

MARK_DIR="/etc/r3s-expand"
STAGE2="/usr/sbin/r3s-expand-stage2.sh"
RCLOCAL="/etc/rc.local"

log(){ echo "[expand] $*"; }
die(){ echo "[expand][FATAL] $*" >&2; exit 1; }

need_root(){ [ "$(id -u)" = "0" ] || die "run as root"; }

resolve_root_dev() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  majmin="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  [ -n "${majmin:-}" ] || die "cannot resolve root dev"
  sys="$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)"
  [ -n "${sys:-}" ] || die "cannot resolve sysfs dev"
  echo "/dev/$(basename "$sys")"
}

split_disk_part() {
  dev="$1"
  case "$dev" in
    /dev/mmcblk*p[0-9]*)
      echo "${dev%p*} ${dev##*p}"
      ;;
    /dev/*[0-9])
      echo "$(echo "$dev" | sed -E 's/[0-9]+$//') $(echo "$dev" | sed -E 's/^.*[^0-9]([0-9]+)$/\1/')"
      ;;
    *)
      die "unsupported root dev: $dev"
      ;;
  esac
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

# idempotent
[ -f "$MARK_DIR/stage2_done" ] && exit 0

ROOT_DEV="$(resolve_root_dev)"
log "root device: $ROOT_DEV"

LOOP_DEV="$(losetup -f)"
losetup "$LOOP_DEV" "$ROOT_DEV"
e2fsck -f -y "$LOOP_DEV" || true
resize2fs "$LOOP_DEV"
losetup -d "$LOOP_DEV" || true

# optional: reduce reserved blocks (if available)
command -v tune2fs >/dev/null 2>&1 && tune2fs -m 1 "$ROOT_DEV" || true

sync
touch "$MARK_DIR/stage2_done"

# remove hook
[ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
exit 0
EOF
  chmod +x "$STAGE2"
}

stage1_resize_partition_with_sfdisk() {
  mkdir -p "$MARK_DIR"
  [ -f "$MARK_DIR/stage1_done" ] && return 0

  ROOT_DEV="$(resolve_root_dev)"
  set -- $(split_disk_part "$ROOT_DEV")
  DISK="$1"
  PARTNUM="$2"

  log "root device: $ROOT_DEV"
  log "disk: $DISK  partnum: $PARTNUM"

  # must have tools
  command -v sfdisk >/dev/null 2>&1 || die "sfdisk not found"
  command -v blockdev >/dev/null 2>&1 || die "blockdev not found"
  command -v losetup >/dev/null 2>&1 || die "losetup not found"
  command -v e2fsck >/dev/null 2>&1 || die "e2fsck not found"
  command -v resize2fs >/dev/null 2>&1 || die "resize2fs not found"

  # backup first 2MiB (partition table area)
  ts="$(date +%Y%m%d_%H%M%S)"
  dd if="$DISK" of="/root/ptable_backup_${ts}.img" bs=1M count=2 >/dev/null 2>&1 || true

  total="$(blockdev --getsz "$DISK")"

  # dump current table
  dump="/tmp/pt.sfdisk"
  new="/tmp/pt.new.sfdisk"
  sfdisk -d "$DISK" >"$dump"

  # extract start of ROOT_DEV from dump
  start="$(awk -v p="$ROOT_DEV" '
    $1==p {for(i=1;i<=NF;i++) if($i ~ /^start=/){gsub(/start=/,"",$i); gsub(/,/, "", $i); print $i; exit}}
  ' "$dump")"
  [ -n "${start:-}" ] || die "cannot parse start sector from sfdisk dump"

  # compute new size to end-of-disk
  newsize=$(( total - start ))
  [ "$newsize" -gt 0 ] || die "computed size invalid"

  log "start=$start  total=$total  new_size=$newsize"

  # replace size= for ROOT_DEV line only
  awk -v p="$ROOT_DEV" -v ns="$newsize" '
    $1==p {
      sub(/size=[0-9]+/, "size="ns);
    }
    {print}
  ' "$dump" >"$new"

  # write table back; --no-reread because disk is in use; reboot will reload table
  sfdisk --no-reread --force "$DISK" <"$new"

  touch "$MARK_DIR/stage1_done"
}

main() {
  need_root

  mkdir -p "$MARK_DIR"

  # stage2 already done
  if [ -f "$MARK_DIR/stage2_done" ]; then
    log "already completed"
    exit 0
  fi

  # install tools (your opkg info/*.list 已经被你删过，会一直刷 warning；不影响安装成功)
  opkg update >/dev/null 2>&1 || true
  opkg install sfdisk losetup resize2fs e2fsprogs tune2fs blockdev >/dev/null 2>&1 || true

  write_stage2
  install_stage2_hook

  stage1_resize_partition_with_sfdisk

  log "partition updated; rebooting to reload partition table; stage2 will run on boot"
  sync
  reboot
}

main
