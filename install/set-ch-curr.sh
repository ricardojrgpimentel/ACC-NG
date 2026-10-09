set_ch_curr() {

  local verbose=${verbose:-true}

  # A default request must neither discover controls nor wait for a charger.
  if [ "${1-}" = - ] && [ ! -s "$TMPDIR/.mcc-custom" ]; then
    maxChargingCurrent=()
    max_charging_current=
    return 0
  fi
  if [ -z "${1-}" ]; then
    ! ${isAccd:-false} || verbose=false
    ! $verbose && echo ${maxChargingCurrent[0]-} \
      || echo "${maxChargingCurrent[0]:-$(print_default)}$(print_mA)"
    return 0
  fi

  $verbose || {
    exxit() { exit $?; }
    . $execDir/misc-functions.sh
  }

  ! ${isAccd:-false} || verbose=false

  # check support
  if [ "${1-}" != - ] && { [ ! -f $TMPDIR/.ch-curr-read ] \
    || ! grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null; }
  then
    if not_charging; then
      ! $verbose || {
        print_read_curr
        print_wait_plug
        echo
      }
      (while not_charging; do sleep 1; set +x; done)
    fi
    . $execDir/read-ch-curr-ctrl-files-p2.sh
    grep -q / $TMPDIR/ch-curr-ctrl-files || {
      ! $verbose || print_no_ctrl_file
      return 1
    }
  fi

  if [ -n "${1-}" ]; then

    # restore
    if [ $1 = - ]; then
      apply_limit current default || return 1
      maxChargingCurrent=()
      max_charging_current=
      ! $verbose || print_curr_restored

    else

      apply_current() {
        eval "
          if [ $1 -ne 0 ]; then
            maxChargingCurrent=($1 $(sed "s|::v|::$1|" $TMPDIR/ch-curr-ctrl-files))
          else
            maxChargingCurrent=($1 $(sed "s|::v.*::|::$1::|" $TMPDIR/ch-curr-ctrl-files))
          fi
        " \
          && unset max_charging_current mcc \
          && apply_limit current value "${maxChargingCurrent[@]}" \
          && {
            ! $verbose || print_curr_set $1
          } || return 1
      }

      # [0-9999] milliamps range
      if [ $1 -ge 0 -a $1 -le 9999 ]; then
        apply_current $1 || return 1
      else
        ! $verbose || echo "[0-9999]$(print_mA; print_only)"
        return 11
      fi
    fi

  else
    # print current value
    ! $verbose && echo ${maxChargingCurrent[0]-} \
      || echo "${maxChargingCurrent[0]:-$(print_default)}$(print_mA)"
    return 0
  fi
}
