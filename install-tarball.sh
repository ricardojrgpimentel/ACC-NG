#!/system/bin/sh
# ${1:-$id} Tarball Installer
# Copyright 2019-2022, VR25
# License: GPLv3+
#
# this file must be in the same directory as the tarball
# $1: module id
# $2: parent install dir, optional
# example: sh install-tarball.sh acc /data/data/github.vr25.acc/files

id=acc
domain=vr25
data_dir=/data/adb/$domain/${1:-$id}-data

# log
[ -z "${LINENO-}" ] || export PS4='$LINENO: '
mkdir -p $data_dir/logs
exec 2>$data_dir/logs/install-tarball.sh.log
set -x

# set up busybox
#BB#
bin_dir=/data/adb/vr25/bin
busybox_dir=/dev/.vr25/busybox
magisk_busybox="/data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox"
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

# root check
[ $(id -u) -ne 0 ] && {
  echo "$0 must run as root (su)"
  exit 4
}

set -e

# get into the target directory
[ -f $PWD/${0##*/} ] || cd $(readlink -f ${0%/*})

# Only regular files/directories beneath one NG archive root are extracted.
ng_archive_valid() (
  local archive=$1 listing= root= details= errors=
  errors=$(mktemp "${archive}.check.XXXXXX") || return 1
  trap 'rm -f "$errors"' EXIT
  [ -s "$archive" ] || return 1
  listing=$(timeout 15 tar -tzf "$archive" 2>"$errors") || return 1
  [ ! -s "$errors" ] || return 1
  root=$(printf '%s\n' "$listing" | sed -n '1s|/.*||p')
  case "$root" in acc-ng-*|ACC-NG-*) :;; *) return 1;; esac
  printf '%s\n' "$listing" | awk -v root="$root" '
    $0 !~ /^[a-zA-Z0-9_.\/:+@=-]+$/ { bad=1 }
    $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /^\// { bad=1 }
    index($0, root "/") != 1 { bad=1 }
    END { exit bad }' || return 1
  details=$(timeout 15 tar -tvzf "$archive" 2>"$errors") || return 1
  [ ! -s "$errors" ] || return 1
  printf '%s\n' "$details" | awk '{ total += $3; count++ } total > 134217728 || count > 4096 { bad=1 } substr($0,1,1) != "-" && substr($0,1,1) != "d" { bad=1 } END { exit bad }'
)

# this runs on exit if the installer is launched by a front-end app
copy_log() {
  [ -z "${original_dir-}" ] || cd "$original_dir"
  [ -z "${extract_dir-}" ] || rm -rf "$extract_dir"
  case "$PWD" in
    /data/data/*|/data/user/*)
      mkdir -p logs
      cp -af $data_dir/logs/install.log logs/${1:-$id}-install.log 2>/dev/null || return 0
      chown -R $(stat -c %u:%g .) logs
      /system/bin/restorecon -R logs
    ;;
  esac
}
trap copy_log EXIT

# Extract only the selected archive in a directory owned by this invocation.
set -- "$@"
archive=
for candidate in acc[-_]*.tgz acc[-_]*.tar.gz; do
  [ -f "$candidate" ] || continue
  [ -z "$archive" ] || exit 5
  archive=$PWD/$candidate
done
ng_archive_valid "$archive" || exit 5
original_dir=$PWD
extract_dir=$(mktemp -d "$PWD/.acc-ng-extract.XXXXXX") || exit 5
tar -xzf "$archive" -C "$extract_dir" || exit 5
cd "$extract_dir"

# The bundled package uses acc-ng-*, while GitHub source archives use ACC-NG-*.
# Accept only one source with our API marker; never select an upstream archive.
select_source() {
  local candidate= selected=
  for candidate in acc[-_]*/ ACC-NG-*/; do
    [ -f "${candidate}module.prop" ] || continue
    [ "$(sed -n 's/^ngApiVersion=//p' "${candidate}module.prop")" = 1 ] || continue
    [ -f "${candidate}install.sh" ] || continue
    [ -z "$selected" ] || return 1
    selected=${candidate%/}
  done
  [ -n "$selected" ] || return 1
  printf '%s' "$selected"
}
src_dir=$(select_source) || exit 5

# prevent frontends from downgrading/reinstalling modules
case "$original_dir" in
  /data/data/*|/data/user/*)
    get_ver() { sed -n '/^versionCode=/s/.*=//p' ${1}module.prop 2>/dev/null || echo 0; }
    bundled_ver=$(get_ver "$src_dir/")
    regular_ver=$(get_ver /data/adb/$domain/${1:-$id}/)
    if [ "$(sed -n 's/^ngApiVersion=//p' /data/adb/$domain/${1:-$id}/module.prop 2>/dev/null)" = 1 ] && [ $bundled_ver -le $regular_ver ] && [ $regular_ver -ne 0 ]; then
      ln -sfn $(readlink -f /data/adb/$domain/${1:-$id}) .
      exit 0
    fi 2>/dev/null || :
  ;;
esac

# install ${1:-$id}
export ACCA_FILES="$original_dir"
export installDir="${2:-$original_dir}"
/system/bin/sh "$src_dir/install.sh"

exit 0
