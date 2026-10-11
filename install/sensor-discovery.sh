# Read-only battery discovery. Keep physical telemetry separate from input
# current and Android's potentially masked battery service.
ng_sensor_number() {
  local value=
  case "$1" in *[!a-zA-Z0-9_./:-]*) return 1;; esac
  [ -f "$1" ] || return 1
  value=$(cat "$1" 2>/dev/null) || return 1
  printf '%s\n' "$value" | grep -Eq '^[+-]?[0-9]{1,9}$' || return 1
  # Decimal conversion avoids octal arithmetic for OEM leading zeroes.
  awk -v n="$value" 'BEGIN {printf "%.0f\n", n}'
}

ng_sensor_status() {
  case "$1" in *[!a-zA-Z0-9_./:-]*) return 1;; esac
  local value=$(cat "$1" 2>/dev/null) || return 1
  case "$value" in Charging|Discharging|Full|Idle|Unknown|Not?charging) printf '%s\n' "$value";; *) return 1;; esac
}

ng_sensor_factor() {
  local file=$1 value=$2 unit= explicit=
  for explicit in "${file}_unit" "${file%/*}/current_unit"; do
    [ -f "$explicit" ] || continue
    unit=$(cat "$explicit" 2>/dev/null) || return 1
    case "$unit" in mA) echo 1000;; uA|µA) echo 1000000;; *) return 1;; esac
    return 0
  done
  case "${ampFactor-}" in 1000|1000000) printf '%s\n' "$ampFactor"; return 0;; esac
  [ "${value#-}" -lt 16000 ] && echo 1000 || echo 1000000
}

ng_discover_battery() {
  local file= value= dir= kind= candidate= previous= factor= millivolts=
  batt= battCapacity= battStatus= temp= currFile= voltNow=
  hasCurrentSensor=false; currentIsBattery=false; hasTemperatureSensor=false
  hasVoltageSensor=false; ampFactor_=1000; voltFactor=1000
  # Prefer known battery/fuel-gauge nodes; do not require uevent.
  for file in maxfg/capacity battery/capacity ds????-fuelgauge/capacity */capacity; do
    value=$(ng_sensor_number "$file") || continue
    [ "$value" -ge 0 ] && [ "$value" -le 100 ] || continue
    dir=${file%/*}
    kind=$(cat "$dir/type" 2>/dev/null || :)
    case "$dir:$kind" in *:Battery|battery:*|maxfg:*|ds????-fuelgauge:*) :;;
      *) previous=$(ng_sensor_status "$dir/status") || continue;; esac
    for candidate in sm????_bms/status "$dir/status" smb???-battery/status; do
      previous=$(ng_sensor_status "$candidate") || continue
      batt=$dir; battCapacity=$file; battStatus=$candidate; break
    done
    [ -z "$batt" ] || break
  done
  [ -n "$batt" ] || return 1

  for file in "$batt/temp" "$batt/batt_temp" bms/temp "${battStatus%/*}/temp"; do
    value=$(ng_sensor_number "$file") || continue
    [ "$value" -ge -500 ] && [ "$value" -le 1500 ] || continue
    temp=$file; hasTemperatureSensor=true; break
  done
  for file in battery/current_now "$batt/current_now" bms/current_now \
    battery/?attery?verage?urrent "${battStatus%/*}/current_now" rt*-charger/current_now; do
    value=$(ng_sensor_number "$file") || continue
    factor=$(ng_sensor_factor "$file" "$value") || continue
    currFile=$file; ampFactor_=$factor; hasCurrentSensor=true
    case "$file" in rt*-charger/*) currentIsBattery=false;; *) currentIsBattery=true;; esac
    break
  done
  for file in "$batt/voltage_now" "$batt/batt_vol" bms/voltage_now "${battStatus%/*}/voltage_now"; do
    value=$(ng_sensor_number "$file") || continue
    [ "$value" -gt 0 ] || continue
    [ "$value" -lt 16000 ] && factor=1000 || factor=1000000
    # Battery voltage plausibility, independent of units.
    if [ "$factor" = 1000000 ]; then millivolts=$((value / 1000)); else millivolts=$value; fi
    [ "$millivolts" -ge 2000 ] && [ "$millivolts" -le 6000 ] || continue
    voltNow=$file; voltFactor=$factor; hasVoltageSensor=true; break
  done
  # Empty placeholders keep legacy cat callers defined without a fabricated
  # measurement. The control loop rejects unavailable protective telemetry.
  : > "$TMPDIR/.unavailable-temp"; : > "$TMPDIR/.dummy-curr"; : > "$TMPDIR/.unavailable-volt"
  temp=${temp:-$TMPDIR/.unavailable-temp}
  currFile=${currFile:-$TMPDIR/.dummy-curr}
  voltNow=${voltNow:-$TMPDIR/.unavailable-volt}
}

ng_telemetry_valid() {
  local value= threshold=
  value=$(ng_sensor_number "$battCapacity") || return 1
  [ "$value" -ge 0 ] && [ "$value" -le 100 ] || return 1
  value=$(ng_sensor_number "$temp") || return 1
  [ "$value" -ge -500 ] && [ "$value" -le 1500 ] || return 1
  for threshold in "${capacity[@]-}"; do
    case "$threshold" in *[!0-9]*|'') continue;; esac
    [ "$threshold" -gt 3000 ] || continue
    value=$(ng_sensor_number "$voltNow") || return 1
    [ "$value" -gt 0 ] || return 1
  done
}

ng_print_sensor_status() {
  local value= role=input
  printf 'sensorStatusVersion=1\n'
  value=$(ng_sensor_status "$battStatus") && printf 'status=%s\n' "$value"
  value=$(ng_sensor_number "$battCapacity") && printf 'capacity=%s\n' "$value"
  if value=$(ng_sensor_number "$currFile"); then
    printf 'current=%s\nfactor=%s\n' "$value" "$ampFactor_"
    if ${currentIsBattery:-true}; then role=battery; printf 'sensor=true\n'
    else printf 'sensor=false\n'; fi
  else printf 'sensor=false\n'; fi
  printf 'currentSource=%s\ncurrentRole=%s\n' "$currFile" "$role"
  if [ -f "$TMPDIR/.current-status-disabled" ]; then printf 'currentStatusAllowed=false\n'
  else printf 'currentStatusAllowed=true\n'; fi
  value=$(ng_sensor_number "$temp") && printf 'temperature=%s\n' "$value"
  if value=$(ng_sensor_number "$voltNow"); then
    printf 'voltage=%s\nvoltageFactor=%s\n' "$value" "${voltFactor:-1000}"
  fi
  return 0
}
