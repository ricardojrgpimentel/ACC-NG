#!/system/bin/sh
# Advanced Charging Controller
# Copyright 2017-2023, VR25
# License: GPLv3+


_batt_info() {
  set +e
  dsys="$(dumpsys battery)"

  {
    {

      if tt "${dsys:-x}" "*reset*"; then

        status=$(echo "$dsys" | sed -n 's/^  status: //p')
        level=$(echo "$dsys" | sed -n 's/^  level: //p')
        powered=$(echo "$dsys" | grep ' powered: true' > /dev/null && echo true || echo false)

        cmd_batt reset
        dumpsys battery
        cmd_batt set status $status
        cmd_batt set level $level

        if $powered; then
          cmd_batt set ac 1
        else
          cmd_batt unplug
        fi

      else
        echo "$dsys"
      fi

    } | grep -Ei "${1-.*}" | sed -e '1s/.*/Battery Service\n/' && echo

    . $execDir/batt-info.sh
    printf "Uevent\n\n"
    batt_info "${1-}" | sed 's/^/  /'

  } | more
}


daemon_ctrl() {

  local isRunning=false

  flock -n 0 <>$TMPDIR/acc.lock || isRunning=true

  case "${1-}" in

    start)
      if $isRunning; then
        print_already_running
        return 8
      else
        print_started
        echo
        exec $TMPDIR/accd $config
      fi
    ;;

    stop)
      if $isRunning; then
        . $execDir/release-lock.sh
        print_stopped
        return 0
      else
        print_not_running
        return 9
      fi
    ;;

    restart)
      if $isRunning; then
        print_restarted
      else
        print_started
      fi
      echo
      exec $TMPDIR/accd $config
    ;;

    *)
      if $isRunning; then
        print_is_running "$accVer ($accVerCode)" "(PID $(cat $TMPDIR/acc.lock))"
        return 0
      else
        print_not_running
        return 9
      fi
    ;;
  esac
}


edit() {
  local file="$1"
  shift
  case "${1-}" in
    a) shift
       if [ "$file" = "$config" ]; then
         . "$execDir/config-transaction.sh"
         ng_add_script "$@"
       else printf '\n%s\n' "$*" >> "$file"; fi;;
    d) sed -Ei "\#$2#d" $file;;

    g) [ "$file" = "$config" ] || {
         install -m 666 $file /data/local/tmp/
         file=/data/local/tmp/${file##*/}
       }
       shift
       ext_app $file "$@";;

    "") case $file in
          *.log|*.md|*.help) less $file;;
          *) nano -$ $file || vim $file || vi $file || ext_app $file;;
        esac 2>/dev/null;;
    *) IFS="$(printf ' \t\n')" eval "$* $file";;
  esac
}


ext_app() {
  am start -a android.intent.action.${2:-EDIT} \
           -t "text/${3:-plain}" \
           -d file://$1 \
           --grant-read-uri-permission &>/dev/null || :
}


get_prop() { sed -n "s|^$1=||p" ${2:-$config}; }


test_charging_switch() {
  . "$execDir/switch-test.sh"
  ng_test_switch "$@"
}


exxit() {
  local exitCode=$?
  set +eux
  ! ${noEcho:-false} && ${verbose:-true} && echo
  tt "$exitCode" "[05689]" || {
    tt "$exitCode" "[127]|10" && logf --export
    echo
  }
  cd /
  exit $exitCode
}


parse_switches() {

  local f=$TMPDIR/.parse_switches.tmp
  local i=
  local n=

  [ -n "${2-}" ] || set -- $TMPDIR/ch-switches "${1-}"

  if [ -z "${2-}" ]; then
    set -- $1 $(echo $dataDir/logs/power_supply-${device}.log)
    [ -f $2 ] || $execDir/power-supply-logger.sh
  fi

  cat -v "$2" > $f

  for i in $(grep -Ein '^  ((1|0)$|.*able.*)' $f | cut -d: -f1); do

    n=$i
    i="$(sed -n "$(($n - 1))p" "$f")"
    n=$(sed -n ${n}p $f | sed 's/^  //')

    case $n in
      0) n="$n 1";;
      1) n="$n 0";;
      disable) n="$n enable";;
      disabled) n="$n enabled";;
      enable) n="$n disable";;
      enabled) n="$n disabled";;
      DISABLE) n="$n ENABLE";;
      DISABLED) n="$n ENABLED";;
      ENABLE) n="$n DISABLE";;
      ENABLED) n="$n DISABLED";;
      *) continue;;
    esac

    i=${i#*/power_supply/}

    # exclude all known switches
    ! grep -q "$i " $1 || continue

    i="$(echo "$i $n" | grep -Eiv 'authentic|brightness|calibrat|capacitance|count|curr|cycle|daemon|demo|design|detect|disk|empty|factory|fast|fcc|flash|full|info|init|learn|mask|moist|nvram|online|otg|parallel|present|priority|protect|reboot|refcnt|report|resistance|reset|reverse|scale|time|rx_|ship|shutdown|state|status|step|sync|temp|timer|tx_|type|update|user|vbus|verif|volt|wait|wake|runtime|mem_state|store_mode')" || :

    [ -z "$i" ] || {
      (set -- $i; ng_filter_switch "$1" "$2" "$3") || :
    }

  done

  rm $f
}


rollback() {
  . "$execDir/rollback.sh"
  ng_rollback "${1-}"
}


set_prop_() {
  . $execDir/set-prop.sh
  set_prop "$@"
}


! ${verbose:-true} || echo
execDir=/data/adb/vr25/acc
defaultConfig=$execDir/default-config.txt

# load generic functions
. $execDir/logf.sh
. $execDir/misc-functions.sh

if [ "${1:-y}" = -x ] || tt "${2-}" "p|parse"; then
  log=/sdcard/Download/acc-${device}.log
  [ $1 != -x ] || shift
else
  log=$TMPDIR/acc-${device}.log
fi

# verbose
if ${verbose:-true} && ! tt "${1-}" "-l*|--log*|-w*|--watch*"; then
  [ -z "${LINENO-}" ] || export PS4='$LINENO: '
  touch $log
  [ $(du -k $log | cut -f 1) -ge 256 ] && : > $log
  echo "###$(date)###" >> $log
  echo "versionCode=$(sed -n s/versionCode=//p $execDir/module.prop 2>/dev/null)" >> $log
  set -x 2>>$log
fi


accVer=$(get_prop version $execDir/module.prop)
accVerCode=$(get_prop versionCode $execDir/module.prop)

unset -f get_prop


misc_stuff "${1-}"
! tt "${1-}" "*/*" || shift


src_cfg


# load default language (English)
. $execDir/strings.sh

# load translations
: ${language:=en}
if ${verbose:-true} && [ -f $execDir/translations/$language/strings.sh ]; then
  . $execDir/translations/$language/strings.sh
fi

grep -q .. $execDir/translations/$language/README.html 2>/dev/null \
  && readMe=$execDir/translations/$language/README.html \
  || readMe=$dataDir/README.html


# aliases/shortcuts
# daemon_ctrl status (acc -D|--daemon): "accd,"
# daemon_ctrl stop (acc -D|--daemon stop): "accd."
! tt "$0" "*accd*" || {
  case $0 in
    *accd.) daemon_ctrl stop;;
    *) daemon_ctrl;;
  esac
  exit $?
}


case "${1-}" in

  "")
    . $execDir/wizard.sh
    wizard
  ;;

  [0-9]*)
    pause_capacity=$1
    resume_capacity=${2:-5000}
    . $execDir/write-config.sh
  ;;

  --import)
    . "$execDir/config-transaction.sh"
    ng_import_config "${2-}"
  ;;

  -bv)
    # Latest valid NG backup version, with no state changes.
    for backup in $(ls -1dt "$dataDir"/backup/* 2>/dev/null); do
      [ -f "$backup/module/module.prop" ] || continue
      sed -n 's/^version=//p; s/^versionCode=//p' "$backup/module/module.prop"
      break
    done
  ;;

  -b|--rollback)
    rollback "${2-}"
  ;;

  -c|--config)
    shift; edit $config "$@"
  ;;

  -d|--disable)
    shift
    ${verbose:-true} || exec > /dev/null
    ! daemon_ctrl stop > /dev/null || print_stopped
   . $execDir/acquire-lock.sh
    disable_charging "$@"
  ;;

  -D|--daemon)
    shift; daemon_ctrl "$@"
  ;;

  -e|--enable)
    shift
    ${verbose:-true} || exec > /dev/null
    ! daemon_ctrl stop > /dev/null || print_stopped
    . $execDir/acquire-lock.sh
    enable_charging "$@"
  ;;


  -f|--force|--full)

    tt ".${2-}" ".-*" && _two= || _two="${2-}"

    apply_on_boot=
    apply_on_plug=
    cooldown_charge=
    cooldown_current=
    cooldown_custom=
    cooldown_pause=
    max_charging_current="${maxChargingCurrent[*]-}"
    max_charging_voltage="${maxChargingVoltage[*]-}"
    max_temp=${temperature[1]}
    off_mid=false
    resume_temp=${temperature[2]}
    temp_level=$tempLevel
    pause_capacity=${_two:-100}
    resume_capacity=$((pause_capacity - 2))

    cp -p "$config" "$TMPDIR/.acc-f-config"
    config=$TMPDIR/.acc-f-config
    . $execDir/write-config.sh
    print_charging_enabled_until ${_two:-100}%
    echo
    echo ': force_resume=; power=0; ng_power_state || power=$?; [ "$power" != 1 ] || exec "$TMPDIR/accd"' >> "$config"

     # additional options
    case "${2-}" in
      [0-9]*)
        shift 2
        ! tt "${1-}" "-*" || $TMPDIR/acca $config "$@" || :;;
      -*)
        shift
        $TMPDIR/acca $config "$@" || :;;
    esac

    exec $TMPDIR/accd $config
  ;;


  -F|--flash)
    shift
    set +eux
    trap - EXIT
    $execDir/flash-zips.sh "$@"
  ;;


  -H|--health)

    counter=$(set +e; grep -E '[1-9]+' */charge_counter 2>/dev/null | head -n 1 | sed 's/.*://' || :)
    health=
    level=$(cat $batt/capacity)
    mAh=${2-}

    [ -n "$mAh" ] || { echo "${0##*/} $1 <mAh>"; exit; }
    [ -n "$counter" ] || { echo "!"; exit; }

    [ $counter -lt 10000 ] || counter=$(calc $counter / 1000)
    health=$(calc "$counter * 100 / $level * 100 / $mAh" | xargs printf %.1f)
    [ ${health%.*} -le 99 ] && echo ${health}% || echo "!"
  ;;

  -i|--info)
    _batt_info "${2-.*}"
  ;;

  -la)
    shift
    logf --acc "$@"
  ;;

  -le)
    logf --export
  ;;

  -l|--log)
    shift
    logf "$@"
  ;;

  -n|--notif)
    shift
    notif "$*"
  ;;

  -p|--parse)
    shift
    parse_switches "$@"
  ;;

  -r|--readme)
    if [ .${2-} = .g ]; then
      edit $readMe g VIEW html
    else
      edit ${readMe%html}md
    fi
  ;;

  -R|--resetbs)
    dumpsys batterystats --reset
    rm -rf /data/system/battery*stats* 2>/dev/null || :
  ;;

  -sc)
    set_prop_ --current ${2-}
  ;;

  -sd)
    set_prop_ --print-default "${2-.*}"
  ;;

  -sl)
    set_prop_ --lang
  ;;

  -sp)
    set_prop_ --print "${2-.*}"
  ;;

  -sr)
    set_prop_ --reset "$@"
  ;;

  -ss)
    shift
    set_prop_ --charging_switch
  ;;

  -ss::)
    set_prop_ s::
  ;;

  -ss:)
    set_prop_ --charging_switch:
  ;;

  -sv)
    shift
    set_prop_ --voltage "$@"
  ;;

  -s|--set)
    shift
    set_prop_ "$@"
  ;;


  -t|--test|-t[0-9]*)
    case "$1" in -t|--test) ng_test_attempts=6;; *) ng_test_attempts=${1#-t};; esac
    case "$ng_test_attempts" in ''|*[!0-9]*) exit 11;; esac
    [ "$ng_test_attempts" -ge 1 ] && [ "$ng_test_attempts" -le 35 ] || exit 11
    shift
    . "$execDir/switch-test.sh"
    ng_test_command "$@"
    exit $?
  ;;


  -T|--logtail|-L|-T:*) #legacy, AccA
    case "$1" in -T:*)
      filter=${1#-T:}; filter=${filter//,/|}
      tail -F "$TMPDIR"/accd-*.log | awk -v pattern="$filter" 'tolower($0) ~ tolower(pattern) { print; fflush() }';;
      *) tail -F "$TMPDIR"/accd-*.log;;
    esac
  ;;

  -u|--upgrade)
    shift
    local array[0]=
    local insecure=
    local reference=

    for i; do
      array+=("$i")
      case "$i" in
        -c|--changelog)
        ;;
        -f|--force)
        ;;
        -k|--insecure)
          echo "Insecure downloads are disabled"; exit 11
        ;;
        -n|--non-interactive)
        ;;
        *)
          unset array[$((${#array[@]}-1))]
          reference="$i"
        ;;
      esac
    done
    test ${#array[@]} -lt 2 || unset array[0]

    test -n "$reference" || {
      grep -Eq '^version=.*-(beta|dev|rc)' $execDir/module.prop \
        && reference=dev \
        || reference=main
    }

    ! test -f /data/adb/vr25/bin/curl || {
      test -x /data/adb/vr25/bin/curl \
        || chmod -R 0755 /data/adb/vr25/bin
    }

    command -v curl >/dev/null || exit 3
    case "$reference" in -*|*..*|*[!a-zA-Z0-9_./-]*) exit 11;; esac
    curl --fail --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 -Lo "$TMPDIR/install-online.sh.new" \
      "https://raw.githubusercontent.com/ricardojrgpimentel/ACC-NG/$reference/install-online.sh" || exit $?
    /system/bin/sh -n "$TMPDIR/install-online.sh.new" || exit 5
    mv "$TMPDIR/install-online.sh.new" "$TMPDIR/install-online.sh"
    trap - EXIT
    set +eu
    installDir=$(readlink -f $execDir)
    installDir=${installDir%/*}
    . $TMPDIR/install-online.sh "${array[@]}" %$installDir% $reference
  ;;

  -U|--uninstall)
    set +eu
    /system/bin/sh $execDir/uninstall.sh
  ;;

  -v|--version)
    echo "$accVer ($accVerCode)"
  ;;

  -w*|--watch*)
    sleepSeconds=${1#*h}
    sleepSeconds=${sleepSeconds#*w}
    : ${sleepSeconds:=1}
    . $execDir/batt-info.sh
    while :; do
      clear
      batt_info "${2-}"
      sleep $sleepSeconds
      set +x
    done
  ;;

  *)
    . $execDir/print-help.sh
    shift
    print_help_ "$@"
  ;;

esac

exit 0
