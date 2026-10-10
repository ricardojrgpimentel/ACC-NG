set_ch_volt() {
  local requested= entries= code= flags=
  if [ -z "${1-}" ]; then
    ! ${verbose:-true} && echo "${maxChargingVoltage[0]-}" ||
      echo "${maxChargingVoltage[0]:-$(print_default)}$(print_mV)"
    return 0
  fi
  if [ "$1" = - ]; then
    if apply_limit voltage default; then
      maxChargingVoltage=(); unset max_charging_voltage mcv
      ng_limit_result voltage default off
      return 0
    fi
    ng_limit_result voltage default failed; return 1
  fi
  set -- $*
  case " $* " in *\ --exit\ *) flags=--exit;; esac
  requested=$(ng_uint "$1") || return 11
  [ "$requested" -ge 3700 ] || requested=3700
  [ "$requested" -le 4300 ] || requested=4300
  maxChargingVoltage=("$requested" ${flags:+$flags})
  unset max_charging_voltage mcv
  if ng_discover_controls voltage; then :
  else
    code=$?
    [ "$code" = 2 ] && { ng_limit_result voltage "$requested" pending; return 0; }
    ng_limit_result voltage "$requested" failed; return 1
  fi
  if [ ! -s "$TMPDIR/ch-volt-ctrl-files" ]; then
    ng_limit_result voltage "$requested" unsupported; return 1
  fi
  entries=$(ng_resolve_limit voltage "$requested") || return 1
  maxChargingVoltage=("$requested" $entries ${flags:+$flags})
  if apply_limit voltage value "${maxChargingVoltage[@]}"; then
    ng_limit_result voltage "$requested" applied
  else
    ng_limit_result voltage "$requested" failed; return 1
  fi
}
