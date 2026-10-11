# Bounded switch probes. The configuration is read, never rolled back by a probe.
ng_test_time() { date +%s; }
ng_test_budget() { [ "$(ng_test_time)" -lt "$ng_test_deadline" ] && [ ! -f "$TMPDIR/.test-cancel" ]; }

ng_test_restore() {
  local entry= file= value= failed=0
  [ -f "$ng_test_snapshot" ] || return 0
  while IFS= read -r entry; do
    file=${entry%%::*}; value=${entry#*::}
    write_control "$value" "$file" && [ "$(cat "$file" 2>/dev/null)" = "$value" ] || failed=1
  done < "$ng_test_snapshot"
  [ "$failed" = 0 ]
}

ng_test_sample() {
  local target=$1 count=0 attempts=0 last= value=
  while [ "$attempts" -lt "${ng_test_attempts:-6}" ]; do
    ng_test_budget && ng_telemetry_valid || return 16
    [ "$(cat "$temp")" -lt "$(( ${temperature[1]} * 10 ))" ] || return 16
    attempts=$((attempts + 1))
    flip=
    _status=Unknown
    if not_charging; then :; fi
    value=${_status:-Unknown}
    case "$value" in Charging|Idle|Discharging) :;; *) return 16;; esac
    if [ "$value" = "$last" ]; then count=$((count + 1)); else count=1; last=$value; fi
    if [ "$count" -ge 3 ]; then
      case "$target:$value" in off:Idle|off:Discharging|on:Charging) return 0;; esac
    fi
    [ "$attempts" = "${ng_test_attempts:-6}" ] || sleep 1
  done
  return 10
}

ng_test_switch() {
  local file= original= value= canonical= seen= code=0 idleMode=false
  [ "$#" -le 25 ] || return 10
  chargingSwitch=("$@")
  printf '\n%s\n' "${chargingSwitch[*]}"
  : > "$ng_test_snapshot" || return 7
  set -- "${chargingSwitch[@]}"
  # Snapshot the whole group before touching any driver-coupled aliases.
  while [ "$#" -ge 3 ]; do
    file=$1
    case "$file" in ''|*[!a-zA-Z0-9_./:-]*) return 10;; esac
    [ -f "$file" ] || return 10
    canonical=$(readlink -f "$file") || return 10
    case "|$seen|" in *"|$canonical|"*) :;; *)
      original=$(cat "$file") || return 7
      case "$original" in ''|*'::'*|*'
'*) return 10;; esac
      printf '%s::%s\n' "$file" "$original" >> "$ng_test_snapshot"
      seen=${seen:+$seen|}$canonical;;
    esac
    parse_value "$2" >/dev/null && parse_value "$3" >/dev/null || return 10
    shift 3
  done
  [ "$#" = 0 ] || [ "$*" = -- ] || return 10
  ng_test_budget || return 16
  flip_sw off || code=7
  if [ "$code" = 0 ]; then ng_test_sample off || code=$?; fi
  [ "${_status-}" != Idle ] || idleMode=true
  if [ "$code" = 0 ]; then
    flip_sw on || code=7
    if [ "$code" = 0 ]; then ng_test_sample on || code=$?; fi
  fi
  if ng_test_restore; then : > "$ng_test_snapshot"; else code=7; fi
  if [ "$code" = 0 ]; then
    print_switch_works
    printf '%s\n' "- battIdleMode=$idleMode"
    printf '%s\n' "${chargingSwitch[*]}" >> "$TMPDIR/working-switches"
    $idleMode && return 15 || return 0
  fi
  printf '%s\n' "Switch test failed: $code"
  return "$code"
}

ng_test_command() {
  set +e
  ng_test_deadline=$(( $(ng_test_time) + 45 ))
  ng_test_snapshot=$TMPDIR/.test-snapshot
  ng_test_restart=false
  ng_test_code=16
  exec 8>"$TMPDIR/.ng-test.lock" || exit 16
  flock -n 0 <&8 || { echo 'Switch test busy'; exit 16; }
  if [ -s "$ng_test_snapshot" ]; then ng_test_restore || exit 7; fi
  [ ! -f "$TMPDIR/.test-daemon-was-running" ] || ng_test_restart=true
  rm -f "$TMPDIR/.test-cancel"
  ng_test_finish() {
    trap - EXIT HUP INT TERM
    if ng_test_restore; then rm -f "$ng_test_snapshot";
    else ng_test_code=7; cp "$ng_test_snapshot" "$dataDir/logs/switch-restore-pending"; fi
    rm -f "$TMPDIR/.test-active" "$TMPDIR/.test-daemon-was-running" "$TMPDIR/.sw"
    printf 'result=%s\n' "$ng_test_code" >> "$dataDir/logs/last-switch-test.log"
    if [ -n "${ng_test_daemon_locked-}" ]; then flock -u 0 <&4; exec 4>&-; fi
    flock -u 0 <&8; exec 8>&-
    if $ng_test_restart && [ ! -f "$TMPDIR/.test-cancel" ]; then
      "$TMPDIR/acca" "$config" -D start >/dev/null 2>&1 </dev/null &
    fi
    exit "$ng_test_code"
  }
  trap ng_test_finish EXIT
  trap 'ng_test_code=16; exit 16' HUP INT TERM
  mkdir -p "$dataDir/logs"
  : > "$dataDir/logs/last-switch-test.log"
  : > "$ng_test_snapshot"
  echo "$$" > "$TMPDIR/.test-active"
  if "$TMPDIR/acca" -D >/dev/null 2>&1; then
    ng_test_restart=true
    touch "$TMPDIR/.test-daemon-was-running"
    "$TMPDIR/acca" -D stop >/dev/null 2>&1 || exit 16
  fi
  exec 4>"$TMPDIR/acc.lock" || exit 16
  flock -n 0 <&4 || exit 16
  ng_test_daemon_locked=true
  ng_power_state || { ng_test_code=2; exit 2; }
  ng_telemetry_valid || exit 16
  [ "$(cat "$temp")" -lt "$(( ${temperature[1]} * 10 ))" ] || exit 16
  [ "${1-}" != -- ] || shift
  local quiet=false entry= result=10 any=10
  if [ "${1-}" = q ]; then quiet=true; shift; fi
  [ "${1-}" != -- ] || shift
  : > "$TMPDIR/working-switches"
  if [ "$#" -ge 3 ]; then
    ng_test_switch "$@" > "$dataDir/logs/last-switch-test.log" 2>&1
    ng_test_code=$?
  else
    case "${1-}" in p|parse)
      timeout 10 "$TMPDIR/acc" "$config" --parse "$TMPDIR/.probe-parsed" "$dataDir/logs/power_supply-${device}.log" >/dev/null 2>&1 || { ng_test_code=10; exit 10; }
      set -- "$TMPDIR/.probe-parsed";;
    esac
    local list=${1:-$TMPDIR/ch-switches}
    [ -f "$list" ] || { ng_test_code=10; exit 10; }
    while IFS= read -r entry; do
      case "$entry" in ''|\#*) continue;; esac
      ng_test_budget || { any=16; break; }
      ng_test_switch $entry >> "$dataDir/logs/last-switch-test.log" 2>&1
      result=$?
      case "$result" in
        15) any=15;;
        0) [ "$any" = 15 ] || any=0;;
        16|7) any=$result; break;;
      esac
    done < "$list"
    ng_test_code=$any
  fi
  if $quiet; then
    case "$ng_test_code" in 0) echo Ok;; 15) echo Idle;; *) echo Fail;; esac
  else cat "$dataDir/logs/last-switch-test.log"; fi
  exit "$ng_test_code"
}
