. "$execDir/external-power.sh"
. "$execDir/sensor-discovery.sh"

idle_discharging() {
  case "$curNow" in ''|*[!0-9-]*|-) return 1;; esac
  [ ${curNow#-} -gt $idleThreshold ] || {
    _status=Idle
    return 0
  }
  case "${dischargePolarity-}" in
    +) [ $curNow -ge 0 ] && _status=Discharging || _status=Charging;;
    -) [ $curNow -lt 0 ] && _status=Discharging || _status=Charging;;
    *) [ $curThen = null ] || {
         tt "$curThen,$curNow" "-*,[0-9]*|[0-9]*,-*" && _status=Discharging || _status=Charging
       };;
  esac
}


not_charging() {

  local i=
  local nci=${nci:-15}
  local switch=${flip-}; flip=
  local curThen=$(cat $curThen)
  local idleThreshold=$idleThreshold
  local battStatusOverride="${battStatusOverride-}"
  local battStatusWorkaround=${battStatusWorkaround-}

  tt "${chargingSwitch[$*]-}" "*\ --" || battStatusOverride=

  if ! ${currentIsBattery:-true} || [ -f "$TMPDIR/.current-status-disabled" ] || ! tt "$currFile" "*/current_now"; then battStatusWorkaround=false
  else
    [ ${ampFactor_:-${ampFactor:-1000}} -eq 1000 ] || idleThreshold=${idleThreshold}000
  fi

  if [ -z "${battStatusOverride-}" ] && [ -n "$switch" ]; then
    for i in $(seq $nci); do
      if [ "$switch" = off ]; then
        ! status ${1-} || {
          sleep ${loopDelay[0]}
          ! status ${1-} || return 0
        }
      else
        status ${1-} || return 1
      fi
      [ ! -f $TMPDIR/.nowrite ] || { rm $TMPDIR/.nowrite 2>/dev/null || :; break; }
      [ $i = $nci ] || sleep 3
    done
    [ "$switch" = on ] || return 1
  else
    status ${1-}
  fi
}


online() {
  if ng_power_state; then return 0; else local code=$?; fi
  # Unknown holds calibration; only explicit disconnected is false.
  [ "$code" != 1 ]
}


read_status() {
  local status="$(cat $battStatus)"
  case "$status" in
    Charging|Discharging) printf %s $status;;
    Not?charging) online && printf Idle || printf Discharging;;
    Full|Idle) printf Idle;;
    *) printf Unknown;;
  esac
}


set_temp_level() {
  local a= b=battery/siop_level l=${1:-${tempLevel-}}
  local entries
  entries=()
  [ -n "$l" ] || return 0
  case "$l" in *[!0-9]*) return 11;; esac
  [ "$l" -ge 0 ] && [ "$l" -le 100 ] || return 11
  if [ "$l" -eq 0 ]; then
    apply_limit temperature default
    return $?
  fi
  if [ -f "$b" ]; then
    entries=("$b::$((100 - l))::0")
  else
    for a in */num_system_temp*levels; do
      b=$(echo "$a" | sed 's/\/num_/\//; s/s$//')
      [ -f "$a" ] && [ -f "$b" ] || continue
      local levels=$(cat "$a")
      case "$levels" in ''|*[!0-9]*) continue;; esac
      entries=("${entries[@]-}" "$b::$((levels * l / 100))::0")
    done
  fi
  apply_limit temperature value "${entries[@]-}"
}


status() {

  local i=
  local curNow=$(cat $currFile)

  _status=$(read_status)

  if [ -n "${battStatusOverride-}" ]; then
    if tt "$battStatusOverride" "Discharging|Idle"; then
      local offValue=$(parse_value "${chargingSwitch[2]}") || return 1
      [ "$(cat "${chargingSwitch[0]}")" != "$offValue" ] || _status=$battStatusOverride
    else
      _status=$(set -eu; eval '$battStatusOverride') || :
    fi
  elif $battStatusWorkaround; then
    [ $_status = Idle ] || idle_discharging || :
  fi

  [ -z "${exitCode_-}" ] || echo -e "  switch: ${switch:--} (${swValue:-N/A})\tcurrent: $(calc $curNow \* 1000 / ${ampFactor:-$ampFactor_} | xargs printf %.f)mA ($_status)"

  for i in Discharging DischargingDischarging Idle IdleIdle; do
    [ $i != ${1-}$_status ] || return 0
  done

  return 1
}


volt_now() {
  local value=$(ng_sensor_number "$voltNow") || return 1
  local factor=${voltFactor:-1000}
  [ "$factor" = 1000 ] || [ "$factor" = 1000000 ] || return 1
  if [ "$factor" = 1000000 ]; then echo "$((value / 1000))"; else echo "$value"; fi
}


if ${init:-false}; then

  ampFactor=$(sed -n 's/^ampFactor=//p' "$dataDir/config.txt" 2>/dev/null || :)
  ng_discover_battery || exit 1

  curThen=$TMPDIR/.curr
  rm $curThen 2>/dev/null || :


  echo "ampFactor_=$ampFactor_
batt=$batt
battCapacity=$battCapacity
battStatus=$battStatus
currFile=$currFile
curThen=$curThen
temp=$temp
voltNow=$voltNow
voltFactor=$voltFactor
hasCurrentSensor=$hasCurrentSensor
currentIsBattery=$currentIsBattery
hasTemperatureSensor=$hasTemperatureSensor
hasVoltageSensor=$hasVoltageSensor" > $TMPDIR/.batt-interface.sh

  init=false

else
  touch $TMPDIR/.batt-interface.sh
  . $TMPDIR/.batt-interface.sh
fi

[ -f $curThen ] || echo null > $curThen
