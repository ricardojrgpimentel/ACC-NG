#!/system/bin/sh
# Advanced Charging Controller Daemon (accd)
# Copyright 2017-2023, VR25
# License: GPLv3+


. $execDir/acquire-lock.sh


. "$execDir/engine-state.sh"
init=false

case "$*" in
  *-i*) init=true;;
  *) [ -f $TMPDIR/.config-ver ] || init=true;;
esac


if ! $init; then


  _ge_cooldown_cap() {
    if t ${capacity[1]} -gt 3000; then
      t $(volt_now) -ge ${capacity[1]}
    else
      t $(cat $battCapacity) -ge ${capacity[1]}
    fi
  }


  _ge_pause_cap() {
    if t ${capacity[3]} -gt 3000; then
      t $(volt_now) -ge ${capacity[3]}
    else
      t $(cat $battCapacity) -ge ${capacity[3]}
    fi
  }


  _lt_pause_cap() {
    if t ${capacity[3]} -gt 3000; then
      t $(volt_now) -lt ${capacity[3]}
    else
      t $(cat $battCapacity) -lt ${capacity[3]}
    fi
  }


  _gt_pause_margin() {
    if t ${capacity[3]} -gt 3000; then
      t $(volt_now) -gt $((capacity[3] + 50))
    else t $(cat $battCapacity) -gt ${capacity[3]}; fi
  }

  _gt_resume_cap() {
    if t ${capacity[2]} -gt 3000; then
      t $(volt_now) -gt ${capacity[2]}
    else
      t $(cat $battCapacity) -gt ${capacity[2]}
    fi
  }


  _le_resume_cap() {
    if [ "${ng_pause_reason-}" = temperature ] && tt ${temperature[2]} "*r" && _lt_pause_cap; then
      return 0
    elif t ${capacity[2]} -gt 3000; then
      t $(volt_now) -le ${capacity[2]}
    else
      t $(cat $battCapacity) -le ${capacity[2]}
    fi
  }


  _le_shutdown_cap() {
    if t ${capacity[0]} -gt 3000; then
      t $(volt_now) -le ${capacity[0]}
    else
      t $(cat $battCapacity) -le ${capacity[0]}
    fi
  }


  _uptime() {
    [ $(cut -d '.' -f 1 /proc/uptime) -ge $1 ]
  }


  below_abs_lims() {
    ng_telemetry_valid && _lt_pause_cap && [ $(cat $temp) -lt $(( ${temperature[1]} * 10 )) ] && is_charging
  }


  exxit() {
    exitCode=$?
    ng_engine_state stopped || :
    $persistLog && set +eu || set +eux
    rm $TMPDIR/.forceoff* 2>/dev/null
    trap - EXIT
    [ -n "$1" ] && exitCode=$1
    [ -n "$2" ] && print "$2"
    $persistLog || exec > /dev/null 2>&1
    cmd_batt reset
    grep -Ev '^$|^#' $config > $TMPDIR/.config
    config=$TMPDIR/.config
    apply_on_boot default
    apply_on_plug default
    tempLevel=0
    set_temp_level || :
    enable_charging
    if tt "$exitCode" "[127]"; then
      . $execDir/logf.sh
      (logf --export >/dev/null 2>&1) &
      notif "⚠️ Daemon stopped with exit code $exitCode!"
    fi
    cd /
    echo versionCode=$versionCode
    exit $exitCode
  }


  is_charging() {

    local file=
    local value=
    local isCharging=false

    # source config & set discharge polarity
    set_dp

    if ! not_charging; then
      isCharging=true
      # [auto mode] change the charging switch if charging has not been enabled by acc
      if $chDisabledByAcc && [ -n "${chargingSwitch[0]-}" ] && ! tt "${chargingSwitch[*]}" "*--"; then
        ng_unexpected_charge=$(( ${ng_unexpected_charge:-0} + 1 ))
        if [ "$ng_unexpected_charge" -ge 3 ]; then
          if ng_save_switch ""; then chargingSwitch=(); else src_cfg; fi
          ng_unexpected_charge=0
        fi
      else ng_unexpected_charge=0; fi
      # [auto mode] set charging switch
      if [ -z "${chargingSwitch[0]-}" ]; then
        ng_disable_safe || return 7
        enable_charging
      fi
    else ng_unexpected_charge=0; fi

    [ $currentWorkaround0 = $currentWorkaround ] || exec $TMPDIR/accd --init
    (set +eu; eval '${loopCmd-}') || :

    # shutdown if battery temp >= shutdown_temp
    [ $(cat $temp) -lt $(( ${temperature[3]} * 10 )) ] || shutdown

    [ -z "${cooldownCurrent-}" ] || {
      if [ $(cat $temp) -le $(( ${temperature[2]%r} * 10 )) ] && ! _ge_cooldown_cap; then
        restrictCurr=false
      fi
      if _ge_cooldown_cap || [ $(cat $temp) -ge $(( ${temperature[0]} * 10 )) ] \
        || { ! $isCharging && [ $(cat $temp) -ge $(( ${temperature[2]%r} * 10 )) ]; }
      then
        restrictCurr=true
      fi
    }

    if $isCharging; then

      # set chgStatusCode and capacitySync
      if [ -z "$chgStatusCode" ] && cmd_batt reset \
        && chgStatusCode=$(dumpsys battery 2>/dev/null | sed -n 's/^  status: //p')
      then :; fi

      # read charging current ctrl files (part 2) once
      $chCurrRead || {
        if [ ! -f $TMPDIR/.ch-curr-read ] \
          || ! grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null
        then
          . $execDir/read-ch-curr-ctrl-files-p2.sh
          chCurrRead=true
        fi
      }

      $cooldown || {
        resetBattStatsOnUnplug=true
        if $resetBattStatsOnPlug && ${resetBattStats[2]}; then
          sleep ${loopDelay[0]}
          not_charging || {
            dumpsys batterystats --reset < /dev/null > /dev/null 2>&1
            rm /data/system/batterystats* || :
            resetBattStatsOnPlug=false
          } 2>/dev/null
        fi
      }

      if $restrictCurr && [ -n "${cooldownCurrent-}" ]; then
        $cooldown || (set_ch_curr ${cooldownCurrent:--} || :)
      else
        [ -n "${maxChargingCurrent[0]-}" ] || (set_ch_curr - || :)
        apply_on_plug
      fi

      shutdownWarnings=true

    else

      $rebootResume \
        && le_resume_cap \
        && [ $(cat $temp) -lt $(( ${temperature[1]} * 10 )) ] && {
          notif "⚠️ System will reboot in 60 seconds to re-enable charging! Stop accd to abort."
          sleep 60
          ! not_charging || {
            /system/bin/reboot || reboot
          }
        } || :

      # set dischgStatusCode and capacitySync
      [ -z "$dischgStatusCode" ] && cmd_batt reset \
        && dischgStatusCode=$(dumpsys battery 2>/dev/null | sed -n 's/^  status: //p')

      $cooldown || {
        resetBattStatsOnPlug=true
        if $resetBattStatsOnUnplug && ${resetBattStats[1]}; then
          sleep ${loopDelay[1]}
          ! not_charging Discharging || {
            dumpsys batterystats --reset < /dev/null > /dev/null 2>&1
            rm /data/system/batterystats* || :
            resetBattStatsOnUnplug=false
          } 2>/dev/null
        fi
      }
    fi

    sync_capacity

    # log buffer reset
    [ $(du -k $log | cut -f 1) -lt 256 ] || : > $log

    $isCharging && return 0 || return 1
  }


  ng_cooldown_wait() {
    local seconds=$1 elapsed=0 power=0
    case "$seconds" in ''|*[!0-9]*) return 1;; esac
    while [ "$elapsed" -lt "$seconds" ]; do
      sleep 1
      elapsed=$((elapsed + 1))
      src_cfg
      [ ! -f "$TMPDIR/.config-invalid" ] && ng_telemetry_valid || return 1
      [ "$(cat "$temp")" -lt "$((temperature[3] * 10))" ] || { shutdown; return 1; }
      if [ "$(cat "$temp")" -ge "$((temperature[1] * 10))" ]; then ng_pause_reason=temperature; return 1; fi
      if ! _lt_pause_cap; then ng_pause_reason=limit; return 1; fi
      power=0; ng_power_state || power=$?
      [ "$power" != 1 ] || return 1
    done
  }

  ng_disable_safe() {
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
      disable_charging && return 0
      attempt=$((attempt + 1))
      [ "$attempt" = 3 ] || sleep 1
    done
    printf '%s control-failure attempts=3\n' "$(date +%s)" >> "$dataDir/logs/ng-recovery.log"
    return 7
  }

  ctrl_charging() {

    local count=0

    while :; do

      [ ! -f "$execDir/disable" ] || { ng_engine_state disabled; return 14; }
      if [ -f "$TMPDIR/.config-invalid" ]; then
        ng_engine_state config-invalid
        flip_sw off || :
        sleep ${loopDelay[1]}; src_cfg; continue
      fi
      if ! ng_telemetry_valid; then
        ng_engine_state sensor-wait
        ng_pause_reason=sensor
        # Do not test/cycle unknown controls with missing protective telemetry.
        flip_sw off || :
        if [ ! -f "$TMPDIR/.sensor-fault" ]; then
          touch "$TMPDIR/.sensor-fault"
          notif "Charging protection paused: battery capacity, temperature or voltage sensor unavailable."
        fi
        sleep ${loopDelay[1]}
        src_cfg
        continue
      fi
      ng_engine_state ready
      rm -f "$TMPDIR/.sensor-fault"
      _ge_pause_cap || ng_idle_retries=0

      # Boot load can make net battery current negative even with input ON.
      # A configured pause does not depend on first observing net charging.
      if $offMid && [ -f "$TMPDIR/.minCapMax" ] && _lt_pause_cap && _gt_resume_cap \
        && [ -n "${chargingSwitch[0]-}" ] && [ "$(cat "$temp")" -lt "$(( ${temperature[3]} * 10 ))" ]; then
        ng_pause_reason=reboot
        ng_disable_safe || return 7
        force_off
        sleep ${loopDelay[1]}
        rm "$TMPDIR/.minCapMax" 2>/dev/null || :
        continue
      fi

      if is_charging; then
        ng_observe Charging || :

        # disable charging under <conditions>
        if [ $(cat $temp) -ge $(( ${temperature[1]} * 10 )) ] || _ge_pause_cap; then
          if _ge_pause_cap; then ng_pause_reason=limit; else ng_pause_reason=temperature; fi
          if ! $allowIdleAbovePcap && [ "${ng_idle_retries:-0}" -lt 2 ] && _gt_pause_margin; then
            ng_idle_retries=$(( ${ng_idle_retries:-0} + 1 ))
            # if possible, avoid idle mode when capacity > pause_capacity
            (cat $config > $TMPDIR/.cfg
            config=$TMPDIR/.cfg
            prioritizeBattIdleMode=no
            cycle_switches_off
            echo "chargingSwitch=(${chargingSwitch[@]-})" > $TMPDIR/.sw
            force_off)
            chDisabledByAcc=true
          else
            ng_disable_safe || return 7
            force_off
          fi
          ! ${resetBattStats[0]} || {
            # reset battery stats on pause
            dumpsys batterystats --reset < /dev/null > /dev/null 2>&1
            rm /data/system/batterystats* 2>/dev/null || :
          }
          sleep ${loopDelay[1]}
          rm $TMPDIR/.minCapMax 2>/dev/null || :
          continue
        fi

        # cooldown cycle

        while [ -n "${cooldownRatio[0]-}${cooldownCustom[0]-}" ]; do

          [ $(sed s/-// ${cooldownCustom[0]:-cooldownCustom} 2>/dev/null || echo 0) -ge ${cooldownCustom[1]:-1} ] \
            && cooldownCustom_=true \
            || cooldownCustom_=false

          if [ $(cat $temp) -ge $(( ${temperature[0]} * 10 )) ] \
            || _ge_cooldown_cap || $cooldownCustom_
          then
            cooldown=true
          else
            break
          fi

          below_abs_lims || break

          if [ -z "${cooldownCurrent-}" ]; then
            cmd_batt set status $chgStatusCode
            ng_disable_safe || return 7
            if $cooldownCustom_; then count=${cooldownCustom[3]:-${loopDelay[1]}};
            else count=${cooldownRatio[1]:-${loopDelay[1]}}; fi
            ng_cooldown_wait "$count" || break
            enable_charging
            $capacitySync || cmd_batt reset
            ! $cooldownCustom_ || cooldownRatio[0]=${cooldownCustom[2]:-${loopDelay[0]}}
            count=0
            while [ $count -lt ${cooldownRatio[0]:-${loopDelay[0]}} ]; do
              ng_cooldown_wait 1 || break
              below_abs_lims && count=$(( count + 1 )) || break
            done
          else
            (set_ch_curr ${cooldownCurrent:--} || :)
            if $cooldownCustom_; then count=${cooldownCustom[3]:-${loopDelay[1]}};
            else count=${cooldownRatio[1]:-${loopDelay[1]}}; fi
            ng_cooldown_wait "$count" || break
            [ -n "${maxChargingCurrent[0]-}" ] || (set_ch_curr - || :)
            apply_on_plug
            ! $cooldownCustom_ || cooldownRatio[0]=${cooldownCustom[2]:-${loopDelay[0]}}
            count=0
            while [ $count -lt ${cooldownRatio[0]:-${loopDelay[0]}} ]; do
              ng_cooldown_wait 1 || break
              below_abs_lims && count=$(( count + 1 )) || break
            done
          fi
        done

        cooldown=false
        sleep ${loopDelay[0]}

      else
        ng_observe "${_status:-Discharging}" || :

        # enable charging under <conditions>
        if _le_resume_cap && temp_ok; then
          rm $TMPDIR/.forceoff* 2>/dev/null && sleep ${loopDelay[0]} || :
          enable_charging
        fi

        # auto-shutdown
        if _uptime 900 && not_charging Discharging; then
          if [ ${capacity[0]} -ge 1 ]; then
            # warnings
            ! $shutdownWarnings || {
              if t ${capacity[0]} -gt 3000; then
                ! t $(grep -o '^..' $voltNow) -eq $(( ${capacity[0]%??} + 1 )) \
                  || ! notif "⚠️ WARNING: ~100mV to auto shutdown, plug the charger!" \
                    || sleep ${loopDelay[1]}
              else
                ! t $(cat $battCapacity) -eq $(( ${capacity[0]} + 5 )) \
                  || ! notif "⚠️ WARNING: 5% to auto shutdown, plug the charger!" \
                    || sleep ${loopDelay[1]}
              fi
              shutdownWarnings=false
            }
            # action
            if _le_shutdown_cap; then
              sleep ${loopDelay[1]}
              ! not_charging Discharging || shutdown
            fi
          fi
        fi
        sleep ${loopDelay[1]}
      fi
      # Keep an unresolved boot pause until a switch is selected or the level
      # leaves the interval; observing discharge during boot is not resolution.
      if ! $offMid || ! _lt_pause_cap || ! _gt_resume_cap; then
        rm "$TMPDIR/.minCapMax" 2>/dev/null || :
      fi
    done
  }


  force_off() {
    local f=$TMPDIR/.forceoff
    rm $f* 2>/dev/null || :
    $forceOff || return 0
    f=$f.$(date +%s)
    touch $f
    set +x
    while [ -f $f ] && _gt_resume_cap; do
      flip_sw off || break
      sleep 1
    done &
    set -x
  }


  set_dp() {
    src_cfg
    # Learn over successive loop samples; never wait for the user to unplug.
    [ -z "${dischargePolarity-}" ] && ${currentIsBattery:-true} && $battStatusWorkaround \
      && [ ! -f "$TMPDIR/.current-status-disabled" ] || return 0
    local power=0 curr= sign=
    ng_power_state || power=$?
    if [ "$power" != 1 ]; then ng_dp_samples=0; return 0; fi
    curr=$(ng_sensor_number "$currFile") || { ng_dp_samples=0; return 0; }
    local threshold=$((idleThreshold * ${ampFactor_:-1000} / 1000))
    [ "${curr#-}" -gt "$threshold" ] || { ng_dp_samples=0; return 0; }
    [ "$curr" -gt 0 ] && sign=+ || sign=-
    if [ "${ng_dp_sign-}" = "$sign" ]; then ng_dp_samples=$(( ${ng_dp_samples:-0} + 1 ));
    else ng_dp_sign=$sign; ng_dp_samples=1; fi
    [ "$ng_dp_samples" -ge 3 ] || return 0
    "$TMPDIR/acca" --set "discharge_polarity=$sign" >/dev/null 2>&1 || return 0
    ng_dp_samples=0
  }


  shutdown() {
    /system/bin/am start -n android/com.android.internal.app.ShutdownActivity < /dev/null > /dev/null 2>&1 \
      || /system/bin/reboot -p \
      || reboot -p || :
  }


  sync_capacity() {
    is_android || return 0
    if [ ${capacity[4]} = true ] || ${capacity[5]} || \
      { [ ${capacity[4]} = auto ] \
      && [ $(dumpsys battery 2>/dev/null | sed -n 's/^  level: //p') -ne $(cat $battCapacity) ] \
      && sleep 2 \
      &&  [ $(dumpsys battery 2>/dev/null | sed -n 's/^  level: //p') -ne $(cat $battCapacity) ]; }
    then
      capacitySync=true
      isCharging=${isCharging:-false}
      local isCharging_=$isCharging
      local battCap=$(cat $battCapacity)

      ! ${capacity[5]} || {
        if [ ${capacity[3]} -gt 3000 ]; then
          local maskedCap=$battCap
        else
          local maskedCap=
          if [ ${capacity[0]} -le 0 ]; then
            maskedCap=$(calc $battCap \* 100 / ${capacity[3]} | xargs printf %.f)
          else
            maskedCap=$(calc "($battCap - ${capacity[0]}) * 100 / (${capacity[3]} - ${capacity[0]})" | xargs printf %.f)
          fi
          [ $maskedCap -le 100 ] || maskedCap=100
          [ $maskedCap -ge 0 ] || maskedCap=0
        fi
      }

      ! $cooldown || isCharging=true

      if $isCharging; then
        cmd_batt set ac 1
        cmd_batt set status $chgStatusCode
      else
        cmd_batt unplug
        cmd_batt set status $dischgStatusCode
      fi

      isCharging=$isCharging_

      [ $battCap -lt 2 ] || {
        if ${capacity[5]}; then
          cmd_batt set level $maskedCap
        else
          cmd_batt set level $battCap
        fi
      }
    else
      ! $capacitySync || {
        cmd_batt reset
        capacitySync=false
      }
    fi
  }


  temp_ok() {
    if [ $(cat $temp) -le $(( ${temperature[2]%r} * 10 )) ] \
      || { [ -n "${cooldownCurrent-}" ] && tt "${temperature[2]}" "*r" && [ $(cat $temp) -le $(( ${temperature[0]} * 10 )) ]; }
    then
      return 0
    else
      return 1
    fi
  }


  # load generic functions
  . $execDir/misc-functions.sh
  . $execDir/ng-events.sh


  capacitySync=false
  chCurrRead=false
  chDisabledByAcc=false
  chgStatusCode=""
  cooldown=false
  dischgStatusCode=""
  isAccd=true
  resetBattStatsOnPlug=false
  resetBattStatsOnUnplug=false
  restrictCurr=false
  shutdownWarnings=true
  versionCode=$(sed -n s/versionCode=//p $execDir/module.prop 2>/dev/null || :)


  if [ "${1:-y}" = -x ]; then
    log=/sdcard/Download/accd-${device}.log
    persistLog=true
    shift
  else
    log=$TMPDIR/accd-${device}.log
    persistLog=false
  fi


  # verbose
  [ -z "${LINENO-}" ] || export PS4='$LINENO: '
  echo "###$(date)###" >> $log
  exec >> $log 2>&1
  set -x


  misc_stuff "${1-}"
  . $execDir/oem-custom.sh
  src_cfg
  currentWorkaround0=$currentWorkaround


  apply_on_boot
  touch $TMPDIR/.minCapMax
  ctrl_charging
  exit $?


else

  ng_init_finish() {
    local code=$?
    [ "$code" = 0 ] || ng_engine_state initialization-failed
  }
  trap ng_init_finish EXIT
  [ ! -f "$execDir/disable" ] || { ng_engine_state disabled; exit 14; }
  ng_engine_state initializing

  args="$(echo "$@" | sed -E 's/(--init|-i)//g')"


  # filter out missing and problematic charging switches (those with unrecognized values)

  . "$execDir/control-discovery.sh"
  filter_sw() { ng_filter_switch "$@"; }


  # log
  mkdir -p $TMPDIR $dataDir/logs
  exec > $dataDir/logs/init.log 2>&1
  set -x


  # prepare executables

  #legacy
  ln -fs $execDir/${id}.sh /dev/$id
  ln -fs $execDir/${id}.sh /dev/${id}d,
  ln -fs $execDir/${id}.sh /dev/${id}d.
  ln -fs $execDir/${id}a.sh /dev/${id}a
  ln -fs $execDir/service.sh /dev/${id}d

  mkdir -p $TMPDIR

  ln -fs $execDir/${id}.sh $TMPDIR/$id
  ln -fs $execDir/${id}.sh $TMPDIR/${id}d,
  ln -fs $execDir/${id}.sh $TMPDIR/${id}d.
  ln -fs $execDir/${id}a.sh $TMPDIR/${id}a
  ln -fs $execDir/service.sh $TMPDIR/${id}d
  ln -fs $execDir/uninstall.sh $TMPDIR/uninstall

  if [ -d /sbin ]; then
    if grep -q '^tmpfs / ' /proc/mounts; then
      /system/bin/mount -o remount,rw / \
        || mount -o remount,rw /
    fi
    for h in $TMPDIR/$id \
      $TMPDIR/${id}d, $TMPDIR/${id}d. \
      $TMPDIR/${id}a $TMPDIR/${id}d
    do
      ln -fs $h /sbin/ 2>/dev/null || break
    done
  fi


  # fix Termux's PATH (missing /sbin/)
  termuxSu=/data/data/com.termux/files/usr/bin/su
  grep -q 'PATH=.*/sbin/su' $termuxSu 2>/dev/null && {
    sed '\|PATH=|s|/sbin/su|/sbin|' $termuxSu > ${termuxSu}.tmp
    cat ${termuxSu}.tmp > $termuxSu # preserves attributes
    rm ${termuxSu}.tmp
  }


  # whitelist MTK-specific switch, if necessary
  if test -f /proc/mtk_battery_cmd/current_cmd \
    && ! test -f /proc/mtk_battery_cmd/en_power_path \
    && grep -q "^#/proc/mtk" $execDir/ctrl-files.sh
  then
    sed -i '/^#\/proc\/mtk/s/#//' $execDir/ctrl-files.sh
  fi


  cd /sys/class/power_supply/
  : > $TMPDIR/ch-switches_
  : > $TMPDIR/ch-switches__
  for f in $TMPDIR/plugins/ctrl-files.sh \
    ${execDir}-data/plugins/ctrl-files.sh \
    $execDir/ctrl-files.sh
  do
    [ -f $f ] && . $f && break
  done
  ls_ch_switches | grep -Ev '^#|^$' | \
    while IFS= read -r chargingSwitch; do
      set -f
      set -- $chargingSwitch
      set +f
      [ $# -lt 3 ] && continue
      if [ $# -gt 3 ]; then
        while [ $# -ge 3 ]; do
          if ! filter_sw "$@" >> $TMPDIR/ch-switches__; then
            rm $TMPDIR/ch-switches__
            break
          fi
          [ $# -lt 3 ] || shift 3
        done
        [ -f $TMPDIR/ch-switches__ ] \
          && cat $TMPDIR/ch-switches__ >> $TMPDIR/ch-switches_ \
          && rm $TMPDIR/ch-switches__
      else
        filter_sw "$@" >> $TMPDIR/ch-switches_
      fi
      echo >> $TMPDIR/ch-switches_
    done
  cat $dataDir/logs/parsed.log 2>/dev/null >> $TMPDIR/ch-switches_
  sed -i -e 's/ $//' -e '/^$/d' $TMPDIR/ch-switches_


  # Keep caches/ownership across restarts. Normal loop discovers while charging.
  # Validate every candidate, including old parsed.log entries.
  : > "$TMPDIR/ch-switches.valid"
  while IFS= read -r candidate; do
    set -f
    set -- $candidate
    set +f
    [ "$#" -ge 3 ] || continue
    valid=true; group=
    while [ "$#" -ge 3 ]; do
      if part=$(ng_filter_switch "$1" "$2" "$3"); then group="$group $part"
      else valid=false; break; fi
      shift 3
    done
    [ "$#" = 0 ] || valid=false
    $valid && printf '%s\n' "${group# }" >> "$TMPDIR/ch-switches.valid"
  done < "$TMPDIR/ch-switches_"
  sort -u "$TMPDIR/ch-switches.valid" > "$TMPDIR/ch-switches"
  rm -f "$TMPDIR/ch-switches_" "$TMPDIR/ch-switches__" "$TMPDIR/ch-switches.valid"


  # Recover a killed probe's journal before any normal charging writes.
  if [ -s "$TMPDIR/.test-snapshot" ] || [ -s "$TMPDIR/.test-master-snapshot" ]; then
    . "$execDir/limit-control.sh"
    . "$execDir/switch-test.sh"
    for ng_test_snapshot in "$TMPDIR/.test-snapshot" "$TMPDIR/.test-master-snapshot"; do
      ng_test_restore || { ng_engine_state control-failure; exit 7; }
    done
    if [ -s "$TMPDIR/.test-original-power" ]; then cp "$TMPDIR/.test-original-power" "$TMPDIR/.ng-input-paused"; fi
    rm -f "$TMPDIR/.test-snapshot" "$TMPDIR/.test-master-snapshot" "$TMPDIR/.test-original-power" "$TMPDIR/.test-active" "$TMPDIR/.test-daemon-was-running"
  fi

  # prepare default config help text and version code for oem-custom.sh and write-config.sh
  sed -n '/^# /,$p' $execDir/default-config.txt > $TMPDIR/.config-help
  sed -n '/^configVerCode=/s/.*=//p' $execDir/default-config.txt > $TMPDIR/.config-ver


  ng_engine_state initializing

  # preprocess battery interface
  . $execDir/batt-interface.sh

  # start $id daemon
  rm $TMPDIR/.ghost-charging 2>/dev/null
  exec $0 $args
fi

exit 0
