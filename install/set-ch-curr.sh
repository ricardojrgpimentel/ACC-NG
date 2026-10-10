set_ch_curr() {
  local requested= entries= code=
  if [ -z "${1-}" ]; then
    ! ${verbose:-true} && echo "${maxChargingCurrent[0]-}" ||
      echo "${maxChargingCurrent[0]:-$(print_default)}$(print_mA)"
    return 0
  fi
  if [ "$1" = - ]; then
    if apply_limit current default; then
      maxChargingCurrent=(); unset max_charging_current mcc
      ng_limit_result current default off
      return 0
    fi
    ng_limit_result current default failed
    return 1
  fi
  requested=$(ng_uint "$1") || return 11
  [ "$requested" -le 9999 ] || return 11
  maxChargingCurrent=("$requested")
  unset max_charging_current mcc
  if ng_discover_controls current; then :
  else
    code=$?
    [ "$code" = 2 ] && { ng_limit_result current "$requested" pending; return 0; }
    ng_limit_result current "$requested" failed; return 1
  fi
  if [ ! -s "$TMPDIR/ch-curr-ctrl-files" ]; then
    ng_limit_result current "$requested" unsupported; return 1
  fi
  entries=$(ng_resolve_limit current "$requested") || return 1
  maxChargingCurrent=("$requested" $entries)
  if apply_limit current value "${maxChargingCurrent[@]}"; then
    ng_limit_result current "$requested" applied
  else
    ng_limit_result current "$requested" failed; return 1
  fi
}
