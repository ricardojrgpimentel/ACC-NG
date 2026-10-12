. $execDir/limit-control.sh
. $execDir/control-discovery.sh
. $execDir/ng-power-limits.sh


apply_on_boot() {

  local entry=
  local file=
  local value=
  local default=
  local arg=${1:-value}
  local exitCmd=false
  local force=false
  local oppositeValue=

  [ ${2:-x} != force ] || force=true

  ! tt "${applyOnBoot[*]-}${maxChargingVoltage[*]-}" "*--exit*" || exitCmd=true

  for entry in ${applyOnBoot[@]-}; do
    set -- ${entry//::/ }
    [ -f ${1-//} ] || continue
    file=${1-}
    value=${2-}
    if $exitCmd && ! $force; then
      default=${2-}
    else
      default=${3:-${2-}}
    fi
    [ $arg = default ] && oppositeValue="$value" || oppositeValue="$default"
    write \$$arg $file 0 || :
  done

  ng_apply_config_limits voltage "$arg" || :

  $exitCmd && [ $arg = value ] && exit 0 || :
}


apply_on_plug() {

  local entry=
  local file=
  local value=
  local default=
  local arg=${1:-value}
  local oppositeValue=

  for entry in ${applyOnPlug[@]-}; do
    set -- ${entry//::/ }
    [ -f ${1-//} ] || continue
    file=${1-}
    value=${2-}
    default=${3:-${2-}}
    [ $arg = default ] && oppositeValue="$value" || oppositeValue="$default"
    write \$$arg $file 0 || :
  done
  ng_apply_config_limits both "$arg" || :

}


at() {
  local requested=$1 now=$(date +%H:%M) day=$(date +%Y%m%d) key= stamp=
  shift
  case "$requested" in [0-2][0-9]:[0-5][0-9]|[0-9]:[0-5][0-9]) :;; *) return 11;; esac
  [ "${requested#0}" = "${now#0}" ] || return 0
  key=$(printf '%s' "$requested $*" | cksum | cut -d ' ' -f 1)
  mkdir -p "$dataDir/schedules"
  exec 5>"$dataDir/schedules/.lock" || return 1
  flock -n 0 <&5 || return 0
  stamp=$dataDir/schedules/$key
  if [ "$(cat "$stamp" 2>/dev/null)" = "$day" ]; then
    flock -u 0 <&5; exec 5>&-; return 0
  fi
  printf '%s\n' "$day" > "$stamp"
  flock -u 0 <&5; exec 5>&-
  acc() { "$TMPDIR/acc" "$@"; }
  acca() { "$TMPDIR/acca" "$@"; }
  accd() { "$TMPDIR/accd" "$@"; }
  eval "$*"
}


calc() {
  awk "BEGIN {print $*}" | tr , .
}


cycle_switches() {

  local on=
  local off= candidate= attempts=0 nci=3
  local deadline=$(( $(date +%s) + 45 ))
  local candidates=$(mktemp "$TMPDIR/.switch-cycle.XXXXXX") || return 7
  cp "$TMPDIR/ch-switches" "$candidates" || { rm -f "$candidates"; return 7; }

  while IFS= read -r candidate; do
    [ "$attempts" -lt 16 ] && [ "$(date +%s)" -lt "$deadline" ] || break
    attempts=$((attempts + 1))
    set -f; chargingSwitch=($candidate); set +f

    [ ! -f ${chargingSwitch[0]:-//} ] || {

      if ! flip_sw "$1"; then flip_sw on 2>/dev/null || :; continue; fi

      if [ "$1" = on ]; then
        not_charging || break
      else
        if not_charging ${2-}; then
          # set working charging switch(es)
          ng_save_switch "${chargingSwitch[*]}" || :
          break
        else
          # reset switch/group that fails to comply, and move it to the end of the list
          flip_sw on 2>/dev/null || :
          if ! ${acc_t:-false}; then
            sed -i "\|^${chargingSwitch[*]}$|d" $TMPDIR/ch-switches
            echo "${chargingSwitch[*]}" >> $TMPDIR/ch-switches
          fi
        fi
      fi
    }
  done < "$candidates"
  rm -f "$candidates"
}


cycle_switches_off() {
  case $prioritizeBattIdleMode in
    true) cycle_switches off Idle;;
    no)   cycle_switches off Discharging;;
  esac
  not_charging || cycle_switches off
}


disable_charging() {

  local autoMode=true

  not_charging || {

    ! tt "${chargingSwitch[*]-}" "*--" || autoMode=false

    if tt "${chargingSwitch[0]-}" "*/*"; then
      if [ -f ${chargingSwitch[0]} ]; then
        if ! { flip_sw off && not_charging; }; then
          $isAccd || print_switch_fails "${chargingSwitch[@]-}"
          flip_sw on 2>/dev/null || :
          if $autoMode; then
            unset_switch
            cycle_switches_off
          fi
        fi
      else
        invalid_switch
      fi
    else
      cycle_switches_off
    fi

    if ! not_charging; then
      return 7 # total failure
    fi

    (set +eux; eval '${runCmdOnPause-}') || :
    chDisabledByAcc=true
  }

  if [ -n "${1-}" ]; then
    case $1 in
      *%)
        print_charging_disabled_until $1
        echo
        (set +x
        until [ $(cat $battCapacity) -le ${1%\%} ]; do
          sleep ${loopDelay[1]}
        done)
        enable_charging
      ;;
      *[hms])
        print_charging_disabled_for $1
        echo
        case $1 in
          *h) sleep $(( ${1%h} * 3600 ));;
          *m) sleep $(( ${1%m} * 60 ));;
          *s) sleep ${1%s};;
        esac
        enable_charging
      ;;
      *m[vV])
        print_charging_disabled_until $1 v
        echo
        (set +x
        until [ $(volt_now) -le ${1%m*} ]; do
          sleep ${loopDelay[1]}
        done)
        enable_charging
      ;;
      *)
        print_charging_disabled
      ;;
    esac
  else
    $isAccd || print_charging_disabled
  fi
}


enable_charging() {

  ! not_charging || {

    set_temp_level || :
    [ ! -f $TMPDIR/.sw ] || (. $TMPDIR/.sw; rm $TMPDIR/.sw; flip_sw on) 2>/dev/null || :

    if ! $ghostCharging || { $ghostCharging && online; }; then

      flip_sw on || cycle_switches on

      # detect and block ghost charging
      if ! $ghostCharging && ! not_charging && ! online \
        && sleep ${loopDelay[0]} && ! not_charging && ! online
      then
        ghostCharging=true
        disable_charging > /dev/null
        touch $TMPDIR/.ghost-charging
        wait_plug
        return 0
      fi

    else
      wait_plug
      return 0
    fi

    chDisabledByAcc=false
  }

  if [ -n "${1-}" ]; then
    case $1 in
      *%)
        print_charging_enabled_until $1
        echo
        (set +x
        until [ $(cat $battCapacity) -ge ${1%\%} ]; do
          sleep ${loopDelay[0]}
        done)
        disable_charging
      ;;
      *[hms])
        print_charging_enabled_for $1
        echo
        case $1 in
          *h) sleep $(( ${1%h} * 3600 ));;
          *m) sleep $(( ${1%m} * 60 ));;
          *s) sleep ${1%s};;
        esac
        disable_charging
      ;;
      *m[vV])
        print_charging_enabled_until $1 v
        echo
        (set +x
        until [ $(volt_now) -ge ${1%m*} ]; do
          sleep ${loopDelay[0]}
        done)
        disable_charging
      ;;
      *)
        print_charging_enabled
      ;;
    esac
  else
    $isAccd || print_charging_enabled
  fi
}


flip_sw() {

  flip=$1
  local on=
  local off=
  local oppositeValue= pausedNode= pausedOff=

  set -- ${chargingSwitch[@]-}
  [ -f ${1:-//} ] || return 2
  swValue=
  ( while [ "$#" -ge 3 ]; do
      [ -f "$1" ] && parse_value "$2" >/dev/null && parse_value "$3" >/dev/null || exit 2
      shift 3
    done
    [ "$#" = 0 ] || [ "$*" = -- ]
  ) || return 2

  while [ -f ${1:-//} ]; do

    on="$(parse_value "$2")" || return 1
    if [ $3 = 3600mV ]; then
      off=$(cat $1)
      [ $off -lt 10000 ] && off=3600 || off=3600000
    else
      off="$(parse_value "$3")" || return 1
    fi

    if [ "$on" != "$off" ] && [ -z "$pausedNode" ]; then pausedNode=$1; pausedOff=$off; fi
    [ $flip = on ] && oppositeValue="$off" || { oppositeValue="$on"; cat $currFile > $curThen; }
    write \$$flip $1 || return 1
    # Keep provenance even if a later alias in the group refuses its write.
    if [ "$flip" = off ] && [ "$1" = "$pausedNode" ]; then
      printf '%s::%s\n' "$pausedNode" "$pausedOff" > "$TMPDIR/.ng-input-paused.new" &&
        mv "$TMPDIR/.ng-input-paused.new" "$TMPDIR/.ng-input-paused" || return 1
    fi

    [ $# -lt 3 ] || shift 3
    [ $# -ge 3 ] || break

  done
  if [ "$flip" = off ] && [ -n "$pausedNode" ]; then
    printf '%s::%s\n' "$pausedNode" "$pausedOff" > "$TMPDIR/.ng-input-paused.new" &&
      mv "$TMPDIR/.ng-input-paused.new" "$TMPDIR/.ng-input-paused"
  elif [ "$flip" = on ]; then rm -f "$TMPDIR/.ng-input-paused"; fi
}


invalid_switch() {
  case "${chargingSwitch[*]-}" in *\ --) return 7;; esac
  $isAccd || print_invalid_switch
  unset_switch
  cycle_switches_off
}


is_android() {
  [ ! -d /data/usbmsc_mnt/ ] && [ -x /system/bin/dumpsys ] \
    && ! tt "$(readlink -f $execDir)" "*com.termux*" \
    && pgrep -f zygote >/dev/null
}


misc_stuff() {
  set -eu
  mkdir -p $dataDir 2>/dev/null || :
  [ -f $config ] || cat $execDir/default-config.txt > $config

  # custom config path
  case "${1-}" in
    */*)
      [ -f $1 ] || cp $config $1
      config=$1
    ;;
  esac
  unset -f misc_stuff
}


notif() {
  [ "${ngNotifications-true}" = true ] || return 0
  local message="[$(date +%H:%M:%S)] ${1:-:)}" uid=${2:-2000} quoted=
  case "$uid" in ''|*[!0-9]*) return 11;; esac
  quoted=$(printf '%s' "$message" | awk '{gsub(/\047/, "\047\042\047\042\047"); printf "%s%s", (NR > 1 ? "\n" : ""), $0}')
  (exec 4>&-; timeout 3 su -lp "$uid" -c "/system/bin/cmd notification post -S bigtext -t 'ACC-NG' 'acc-ng-cli' '$quoted'" \
    </dev/null >/dev/null 2>&1 || :) &
  return 0
}


parse_value() {
  case "$1" in
    */*)
      [ -f "$1" ] && [ -r "$1" ] || return 1
      local value=$(cat "$1")
      [ -n "$value" ] || return 1
      printf '%s\n' "$value";;
    *) printf '%s\n' "$1" | sed 's/::/ /g';;
  esac
}


print_header() {
  echo "Advanced Charging Controller NG (ACC-NG) $accVer ($accVerCode)
(C) 2017-2023, VR25
GPLv3+"
}


print_wait_plug() {
  print_unplugged
}


src_cfg() {
  . "$execDir/config-transaction.sh"
  ng_load_config
}


# test
t() { test "$@"; }


# extended test
tt() {
  eval "case \"$1\" in
    $2) return 0;;
  esac"
  return 1
}


unset_switch() {
  ng_save_switch "" || :
}


wait_plug() {
  $isAccd || {
    echo "ghostCharging=true"
    print_wait_plug
  }
  (while ! online; do
    sleep ${loopDelay[1]}
    ! $isAccd || sync_capacity 2>/dev/null || :
    set +x
  done)
  enable_charging "$@"
}


. "$execDir/control-write.sh"


# environment

id=acc
domain=vr25
: ${isAccd:=false}
loopDelay=(3 9)
execDir=/data/adb/$domain/acc
export TMPDIR=/dev/.vr25/acc
: ${config:=/data/adb/$domain/${id}-data/config.txt}
config_=$config
dataDir=/data/adb/$domain/${id}-data

[ -f $TMPDIR/.ghost-charging ] \
  && ghostCharging=true \
  || ghostCharging=false

trap exxit EXIT

. $execDir/setup-busybox.sh
. $execDir/set-ch-curr.sh
. $execDir/set-ch-volt.sh

device=$(getprop ro.product.device | grep .. || getprop ro.build.product)

cd /sys/class/power_supply/
. $execDir/batt-interface.sh

# cmd battery and dumpsys wrappers
if is_android; then
  cmd_batt() { /system/bin/cmd battery "$@" < /dev/null > /dev/null 2>&1 || :; }
  dumpsys() { /system/bin/dumpsys "$@" || :; }
else
  cmd_batt() { :; }
  dumpsys() { :; }
  ! ${isAccd:-false} || {
    chgStatusCode=0
    dischgStatusCode=0
  }
fi

# load plugins
mkdir -p ${execDir}-data/plugins $TMPDIR/plugins
for f in ${execDir}-data/plugins/*.sh $TMPDIR/plugins/*.sh; do
  if [ -f "$f" ] && [ ${f##*/} != ctrl-files.sh ]; then
    . "$f"
  fi
done
unset f
