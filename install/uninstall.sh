#!/sbin/sh
# $id uninstaller
# id is set/corrected by build.sh
# Copyright 2019-2023, VR25
# License: GPLv3+
#
# devs: triple hashtags (###) mark non-generic code

set -u
id=acc
domain=vr25
export TMPDIR=/dev/.$domain/$id

# set up busybox
#BB#
bin_dir=/data/adb/vr25/bin
busybox_dir=/dev/.vr25/busybox
magisk_busybox="/data/adb/ksu/bin/busybox /data/adb/magisk/busybox"
[ -x $busybox_dir/ls ] || {
  mkdir -p $busybox_dir
  chmod 0755 $busybox_dir $bin_dir/busybox 2>/dev/null || :
  for f in $bin_dir/busybox $magisk_busybox /system/*bin/busybox*; do
    [ ! -f $f ] || {
      $f --install -s $busybox_dir/
      break
    }
  done
  [ -x $busybox_dir/ls ] || {
    echo "Install busybox or simply place it in $bin_dir/"
    echo
    exit 3
  }
}
case $PATH in
  $bin_dir:*) ;;
  *) export PATH="$bin_dir:$busybox_dir:$PATH";;
esac
unset f bin_dir busybox_dir magisk_busybox
#/BB#

exec 2>/dev/null

# Calibration subshells inherit the daemon lock and can outlive their parent.
stop_daemon_holders() {
  local signal= pid= command=
  for signal in TERM KILL; do
    for pid in $(pgrep -f '/accd.sh' 2>/dev/null); do
      [ "$pid" != "$$" ] || continue
      command=$(tr '\000' ' ' < /proc/$pid/cmdline 2>/dev/null | sed 's|^/system/bin/sh |sh |; s/ *$//')
      case "$command" in
        "sh /data/adb/vr25/acc/accd.sh"|"sh /data/adb/vr25/acc/accd.sh "*|"sh /data/adb/modules/acc/accd.sh"|"sh /data/adb/modules/acc/accd.sh "*|"sh /dev/.vr25/acc/accd.sh"|"sh /dev/.vr25/acc/accd.sh "*) kill -$signal "$pid" 2>/dev/null || :;;
      esac
    done
    [ "$signal" != TERM ] || sleep 1
  done
}
stop_daemon_holders
mkdir -p "$TMPDIR"
# Never block indefinitely on an obsolete/inherited lock.
timeout 5 flock "$TMPDIR/${id}.lock" true || exit 1
###
pgrep -f "/($id|${id}a) (-|--)[det]|/${id}d" > /dev/null && { #legacy
  pkill -f "/($id|${id}a) (-|--)[det]|/${id}d"
  for count in $(seq 10); do
    sleep 2
    [ -z "$(pgrep -f "/($id|${id}a) (-|--)[det]|/${id}d")" ] && break
  done
  pkill -KILL -f "/($id|${id}a) (-|--)[det]|/${id}d"
}

# Temporary installation sources belong to their callers (tarball/online/app).
# A name-based /data/local/tmp cleanup can delete an active upgrade and the
# uninstall script needed by its recovery trap. Only remove installed paths.
# uninstall $id ###
rm -rf /data/adb/$domain/$id \
  /data/adb/modules/$id \
  /data/adb/service.d/${id}-*.sh \
  /data/data/mattecarra.accapp/files/$id

[ "${1:-}" = install ] || rm -rf /data/adb/$domain/${id}-data
rmdir /data/adb/$domain

#legacy
rm -rf $(readlink -f /data/adb/$id) \
  /data/adb/$id \
  /data/adb/${id}-data \
  $(readlink -f /sbin/.$id/$id) \
  /data/media/0/${id}-logs-*.tar.* \
  /data/media/0/${id}[-_]*uninstaller.zip \
  /data/media/0/.${id}-config-backup.txt \
  /data/media/0/Download/$id \
  /data/media/0/$domain \
  /data/media/0/Documents/$domain/$id \
  /data/data/com.termux/files/home/.termux/boot/${id}-init.sh

exit 0
