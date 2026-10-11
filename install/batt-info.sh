batt_info() {

  local voltagePath=${voltNow-}
  local i=
  local info=
  local voltNow=
  local currNow=
  local powerNow=
  local hasCurrent=false hasVoltage=false
  local factor= rawCurrent= rawVoltage= inputCurrent=
  set +eu


  # calculator
  calc2() {
    awk "BEGIN {print $*}" | tr , . | xargs printf %.2f
  }


  dtr_conv_factor() {
    factor=${2-}
    if [ -z "$factor" ]; then
      case $1 in
        0) factor=1;;
        *) [ $1 -lt 16000 ] && factor=1000 || factor=1000000;;
      esac
    fi
  }


  # raw battery info from the kernel's battery interface
  info="$(
    cat $batt/uevent *bms*/uevent 2>/dev/null \
      | sort -u \
      | sed -E -e 's/^POWER_SUPPLY_//' \
        -e 's/^BATT_VOL=/VOLTAGE_NOW=/' \
        -e 's/^BATT_TEMP=/TEMP=/' \
        -e '/^(CHARGE_TYPE|NAME|POWER_NOW)=/d'\
        -e "/^CAPACITY=/s/=.*/=$(cat $battCapacity)/"
  )"


  # Always supply physical keys, including interfaces without uevent. A
  # selected missing sensor must not fall back to a stale/different uevent.
  not_charging || :
  rawCurrent=$(echo "$info" | sed -n 's/^CURRENT_NOW=//p' | head -n1)
  rawVoltage=$(echo "$info" | sed -n 's/^VOLTAGE_NOW=//p' | head -n1)
  [ -z "${currFile-}" ] || rawCurrent=$(cat "$currFile" 2>/dev/null || :)
  [ -z "$voltagePath" ] || rawVoltage=$(cat "$voltagePath" 2>/dev/null || :)
  info=$(echo "$info" | sed '/^STATUS=/d; /^CAPACITY=/d; /^TEMP=/d; /^CURRENT_NOW=/d; /^VOLTAGE_NOW=/d')
  info="$info
STATUS=$_status
CAPACITY=$(cat "$battCapacity" 2>/dev/null || :)
TEMP=$(cat "$temp" 2>/dev/null || :)
CURRENT_NOW=$rawCurrent
VOLTAGE_NOW=$rawVoltage"

  # parse CURRENT_NOW & convert to Amps
  currNow=$(echo "$info" | sed -n "s/^CURRENT_NOW=//p" | head -n1)
  if printf '%s\n' "$currNow" | grep -Eq '^[+-]?[0-9]+([.][0-9]+)?$'; then
    hasCurrent=true
    if ${hasCurrentSensor:-false}; then dtr_conv_factor ${currNow#-} "$ampFactor_"
    else dtr_conv_factor ${currNow#-} ${ampFactor:-$ampFactor_}; fi
    currNow=$(calc2 "$currNow" / $factor)
    if ! ${currentIsBattery:-true}; then
      inputCurrent=$currNow; hasCurrent=false
      info=$(echo "$info" | sed '/^CURRENT_NOW=/d')
    fi
  else
    currNow=0.00
    info=$(echo "$info" | sed '/^CURRENT_NOW=/d')
  fi


  # add/remove negative sign
  case $currNow in
    0.00)
      :
    ;;
    *)
      if [ $_status = Discharging ]; then
        currNow=-${currNow#-}
      elif [ $_status = Charging ]; then
        currNow=${currNow#-}
      fi
    ;;
  esac


  # parse VOLTAGE_NOW & convert to Volts
  voltNow=$(echo "$info" | sed -n "s/^VOLTAGE_NOW=//p" | head -n1)
  if printf '%s\n' "$voltNow" | grep -Eq '^[+]?[0-9]+([.][0-9]+)?$'; then
    hasVoltage=true
    dtr_conv_factor $voltNow ${voltFactor-}
    voltNow=$(calc2 "$voltNow" / $factor)
  else
    voltNow=0.00
    info=$(echo "$info" | sed '/^VOLTAGE_NOW=/d')
  fi


  # calculate POWER_NOW (Watts)
  powerNow=$(calc2 $currNow \* $voltNow)


  {
    # print raw battery info
    ${verbose:-true} \
      && echo "$info" \
      || echo "$info" | grep -Ev '^(CURRENT|VOLTAGE)_NOW='

    # print CURRENT_NOW, VOLTAGE_NOW and POWER_NOW
    echo
    [ -z "$inputCurrent" ] || echo "INPUT_CURRENT_NOW=$inputCurrent"
    [ -z "${currFile-}" ] || printf 'CURRENT_SOURCE=%s\nCURRENT_ROLE=%s\n' "$currFile" "$(if ${currentIsBattery:-true}; then echo battery; else echo input; fi)"
    ! $hasCurrent || echo "CURRENT_NOW=$currNow$(print_A 2>/dev/null || :)"
    ! $hasVoltage || echo "VOLTAGE_NOW=$voltNow$(print_V 2>/dev/null || :)"
    if $hasCurrent && $hasVoltage; then
      echo "POWER_NOW=$powerNow$(print_W 2>/dev/null || :)"
    fi


  # power supply info
  for i in */online; do
    ! tt "$i" "*[bB][mM][sS]*" || continue
    if [ -f $i ] && [ $(cat $i) -eq 1 ]; then
      i=${i%/*}
      POWER_SUPPLY_TYPE=$(cat $i/real_type 2>/dev/null || echo $i | tr [a-z] [A-Z])

      echo "
CHARGE_TYPE=$POWER_SUPPLY_TYPE"

      POWER_SUPPLY_AMPS=$(dtr_conv_factor $(cat $i/*current_now | tail -n 1) ${ampFactor:-$ampFactor_})

      if [ 0${POWER_SUPPLY_AMPS%.*} -gt 0 ]; then
        POWER_SUPPLY_VOLTS=$(dtr_conv_factor $(cat $i/voltage_now) ${voltFactor-})
        POWER_SUPPLY_WATTS=$(calc2 $POWER_SUPPLY_AMPS \* $POWER_SUPPLY_VOLTS)
        CONSUMED_WATTS=$(calc2 $POWER_SUPPLY_WATTS - $powerNow)

        echo "POWER_SUPPLY_AMPS=$POWER_SUPPLY_AMPS
POWER_SUPPLY_VOLTS=$POWER_SUPPLY_VOLTS
POWER_SUPPLY_WATTS=$POWER_SUPPLY_WATTS
CONSUMED_WATTS=$CONSUMED_WATTS"
      fi

      break
    fi
  done 2>/dev/null || :

  } | sed '/^$/d; /^CAPACITY=$/d; /^TEMP=$/d' | grep -Ei "${1:-.*}" || :
}
