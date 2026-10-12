#!/system/bin/sh
#
# $id Online Installer
# https://raw.githubusercontent.com/ricardojrgpimentel/ACC-NG/$commit/install-online.sh
#
# Copyright 2019-2023, VR25
# License: GPLv3+
#
# Usage: sh install-online.sh [-c|--changelog] [-f|--force] [-k|--insecure] [-n|--non-interactive] [%parent install dir%] [commit]


set +x
echo
id=acc
domain=vr25
data_dir=/data/adb/$domain/${id}-data

# log
[ -z "${LINENO-}" ] || export PS4='$LINENO: '
mkdir -p $data_dir/logs
set -x &>$data_dir/logs/install-online.sh.log

trap 'e=$?; echo; exit $e' EXIT


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


set -eu
get_ver() { sed -n 's/^versionCode=//p' ${1:-}; }


! test -f /data/adb/vr25/bin/curl || {
  test -x /data/adb/vr25/bin/curl \
    || chmod -R 0755 /data/adb/vr25/bin
}


command -v curl >/dev/null || { echo 'A TLS-capable curl is required'; exit 3; }
case "$*" in *--insecure*|*-k*) echo 'Insecure downloads are disabled'; exit 11;; esac
ng_download() {
  curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --max-filesize 52428800 --retry 1 "$1"
}

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

# GitHub strips v from version-tag archive folders. Read the archive instead
# of guessing from a branch, tag or SHA reference.
archive_source() {
  local source=
  source=$(tar -tzf "$1" | sed -n '1s|/.*||p')
  case "$source" in ACC-NG-*) printf '%s' "$source";; *) return 1;; esac
}

commit=$(echo "$*" | sed -E 's/%.*%|-c|--changelog|-f|--force|-k|--insecure|-n|--non-interactive| //g')
: ${commit:=main}
case "$commit" in -*|*..*|*[!a-zA-Z0-9_./-]*) exit 11;; esac

tarball=https://github.com/ricardojrgpimentel/ACC-NG/archive/${commit}.tar.gz

installedVersion=$(get_ver /data/adb/$domain/$id/module.prop 2>/dev/null || :)

onlineMetadata=$(ng_download "https://raw.githubusercontent.com/ricardojrgpimentel/ACC-NG/${commit}/module.prop") || exit $?
[ "$(printf '%s\n' "$onlineMetadata" | sed -n 's/^id=//p')" = acc ] &&
  [ "$(printf '%s\n' "$onlineMetadata" | sed -n 's/^ngApiVersion=//p')" = 1 ] || exit 5
onlineVersion=$(printf '%s\n' "$onlineMetadata" | get_ver)


case "$onlineVersion" in ''|*[!0-9]*) exit 5;; esac

[ -f $PWD/${0##*/} ] || cd $(readlink -f ${0%/*})
[ -z "${reference-}" ] || cd /dev/.$domain/$id



if [ ${installedVersion:-0} -lt ${onlineVersion:-0} ] \
  || case "$*" in *-f*|*--force*) true;; *) false;; esac
then

  ! echo "$@" | grep -Eq '\-\-changelog|\-c' || {
    if echo "$@" | grep -Eq '\-\-non-interactive|\-n'; then
      echo $onlineVersion
      echo "https://github.com/ricardojrgpimentel/ACC-NG/blob/${commit}/changelog.md"
      exit 5 # no update available
    else
      echo
      print_available $id $onlineVersion 2>/dev/null \
        || echo "$id $onlineVersion is available"
      print_install_prompt 2>/dev/null \
        || echo -n "- Download and install? ([enter]: yes, CTRL-C: no) "
      read REPLY
    fi
  }

  # download and install tarball
  : ${installDir:=$(echo "$@" | sed -E "s/-c|--changelog|-f|--force|-k|--insecure|-n|--non-interactive|%|$commit| //g")}
  export installDir
  set +eu
  trap - EXIT
  echo
  work_dir=$(mktemp -d "$PWD/.acc-ng-online.XXXXXX") || exit 5
  archive=$work_dir/source.tgz
  ng_download "$tarball" > "$archive" || { status=$?; rm -rf "$work_dir"; exit "$status"; }
  ng_archive_valid "$archive" || { rm -rf "$work_dir"; exit 5; }
  source_dir=$(archive_source "$archive") || { rm -rf "$work_dir"; exit 5; }
  tar -xzf "$archive" -C "$work_dir" || { rm -rf "$work_dir"; exit 5; }
  [ "$(sed -n 's/^ngApiVersion=//p' "$work_dir/$source_dir/module.prop")" = 1 ] &&
    [ "$(sed -n 's/^id=//p' "$work_dir/$source_dir/module.prop")" = acc ] || { rm -rf "$work_dir"; exit 5; }
  ash "$work_dir/$source_dir/install.sh"
  install_status=$?
  rm -rf "$work_dir"
  exit $install_status

else
  echo
  print_no_update 2>/dev/null || echo "No update available"
  exit 6
fi


set -eu

exit 0
