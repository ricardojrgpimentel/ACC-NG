# Additive NG API 1 control readback. Applied means matching control nodes;
# it does not claim measured battery current equals the requested limit.
ng_limit_result() {
  printf '%s::%s\n' "$2" "$3" > "$TMPDIR/.ng-$1-result.$$" &&
    mv "$TMPDIR/.ng-$1-result.$$" "$TMPDIR/.ng-$1-result"
}

# Apply latest config under the frontend lock; never save a daemon's old config.
ng_apply_config_limits() (
  trap - EXIT HUP INT TERM
  local kind=$1 action=${2:-value}
  exec 7>"$TMPDIR/.ng-config.lock" || return 1
  timeout 5 flock 0 <&7 || return 1
  [ ! -f "$config" ] || . "$config"
  if [ "$kind" = voltage ] || [ "$kind" = both ]; then
    if [ "$action" = default ]; then set_ch_volt - || :
    else set_ch_volt "${maxChargingVoltage[*]:--}" || :; fi
  fi
  if [ "$kind" = current ] || [ "$kind" = both ]; then
    if [ "$action" = default ]; then set_ch_curr - || :
    else set_ch_curr "${maxChargingCurrent[0]:--}" || :; fi
  fi
)

ng_save_switch() (
  trap - EXIT HUP INT TERM
  local selected=$1
  exec 7>"$TMPDIR/.ng-config.lock" || return 1
  timeout 5 flock 0 <&7 || return 1
  . "$config"
  case "${chargingSwitch[*]-}" in *\ --) return 1;; esac
  ng_config_locked=true
  s=$selected
  . "$execDir/write-config.sh"
)

ng_print_limit() {
  local kind=$1 requested=${2:-default} cache= ready= owned= result= state=pending
  local entries= entry= file= expected= actual= supported=unknown
  case "$kind" in
    current) cache=$TMPDIR/ch-curr-ctrl-files; ready=$TMPDIR/.ch-curr-read; owned=$TMPDIR/.mcc-custom;;
    voltage) cache=$TMPDIR/ch-volt-ctrl-files; ready=$TMPDIR/.ch-volt-read; owned=$TMPDIR/.volt-custom;;
  esac
  if [ -f "$ready" ] && [ -f "$cache" ]; then
    if [ -s "$cache" ]; then supported=true; else supported=false; fi
  fi
  result=$(cat "$TMPDIR/.ng-$kind-result" 2>/dev/null) || result=
  if [ "$requested" = default ] || [ "$requested" = - ]; then
    requested=default
    [ -s "$owned" ] && state=failed || state=off
  elif [ "$supported" = false ]; then state=unsupported
  elif [ "$result" = "$requested::failed" ]; then state=failed
  elif [ "$supported" = true ] && [ "$result" = "$requested::applied" ]; then
    entries=$(ng_resolve_limit "$kind" "$requested") || entries=
    if [ -n "$entries" ]; then
      state=applied
      while IFS= read -r entry; do
        file=${entry%%::*}; expected=${entry#*::}; expected=${expected%%::*}
        actual=$(cat "$file" 2>/dev/null) || actual=
        [ "$actual" = "$expected" ] || state=failed
      done <<EOF
$entries
EOF
    else state=failed; fi
  fi
  printf '%s.requested=%s\n%s.supported=%s\n%s.state=%s\n' \
    "$kind" "$requested" "$kind" "$supported" "$kind" "$state"
}

ng_print_power_limits() {
  printf 'powerLimitsVersion=1\n'
  if ng_power_state; then printf 'online=true\n'
  else case "$?" in 1) printf 'online=false\n';; *) printf 'online=unknown\n';; esac; fi
  ng_print_limit current "${maxChargingCurrent[0]:-default}"
  ng_print_limit voltage "${maxChargingVoltage[0]:-default}"
}
