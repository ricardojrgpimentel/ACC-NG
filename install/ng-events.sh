# ACC-NG events. Copyright 2026 Ricardo Pimentel. GPLv3+.
# Inspired by Ian7672's event notifications; independently implemented on ACC.
# This file never switches charging, changes thresholds or invokes shutdown.

ng_online() {
  local file= value= seen=false
  for file in */online; do
    case "$file" in bms/*|battery/*|otg/*) continue;; esac
    value=$(cat "$file" 2>/dev/null) || continue
    case "$value" in 1) return 0;; 0) seen=true;; esac
  done
  $seen && return 1
  return 2
}

ng_emit() {
  local key=$1 en=$2 pt=$3 message=
  case "${ngNotificationLanguage-en}" in pt*) message=$pt;; *) message=$en;; esac
  # Diagnostic history is useful even when user notifications are disabled.
  if [ -d "$dataDir/logs" ]; then
    [ ! -f "$dataDir/logs/ng-events.log" ] || {
      [ $(wc -c < "$dataDir/logs/ng-events.log") -lt 65536 ] || : > "$dataDir/logs/ng-events.log"
    }
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$message" >> "$dataDir/logs/ng-events.log" || :
  fi
  [ "${ngNotifications-true}" = true ] || return 0
  # Run off the control loop, with a bound and a single worker. A failing or
  # hanging Android notification must not delay thermal/charging protection.
  if [ -n "${ng_notification_pid-}" ] && kill -0 "$ng_notification_pid" 2>/dev/null; then return 0; fi
  (timeout 3 su -lp 2000 -c "/system/bin/cmd notification post -S bigtext -t 'ACC-NG' 'acc-ng-status' \"$message\"" < /dev/null > /dev/null 2>&1 || :) &
  ng_notification_pid=$!
  return 0
}

ng_observe() {
  local state=$1 connected=unknown value= temp_now= cap_now= reason=
  if ng_online; then connected=true; else
    value=$?; [ "$value" != 1 ] || connected=false
  fi
  # Unknown/failed sensor data does not imply an unplug or a state transition.
  [ "$connected" != unknown ] || return 0
  if [ "$connected" != "${ng_connected-unknown}" ]; then
    if [ "$connected" = true ]; then
      ng_emit connected 'Charger connected' 'Carregador ligado'
    elif [ "${ng_connected-unknown}" = true ]; then
      ng_emit disconnected 'Charger disconnected' 'Carregador desligado'
    fi
    ng_connected=$connected
    ng_state=unknown
    ng_pause_reason=
    ng_heat=normal
  fi
  if [ "$connected" = true ] && [ "$state" != "${ng_state-unknown}" ]; then
    case "$state" in
      Charging)
        if [ "${ng_state-unknown}" != unknown ]; then
          ng_emit resumed 'Charging resumed' 'Carregamento retomado'
        fi
        ng_pause_reason=
      ;;
      Idle)
        # Idle comes from ACC's battery/current interface, never from SoC alone.
        ng_emit idle 'Battery idle detected' 'Bateria em idle detetada'
      ;;
      *)
        case "${ng_pause_reason-}" in
          limit)
            value=${capacity[3]}; case "$value" in *[!0-9]*|'') value='?';; esac
            if [ "$value" -gt 3000 ] 2>/dev/null; then value="${value}mV"; else value="${value}%"; fi
            ng_emit paused "Charging paused at configured limit: $value" "Carregamento em pausa no limite configurado: $value"
          ;;
          temperature) ng_emit paused 'Charging paused for temperature' 'Carregamento em pausa por temperatura';;
          *) ng_emit paused 'Charging paused' 'Carregamento em pausa';;
        esac
      ;;
    esac
  fi
  ng_state=$state
  temp_now=$(cat "$temp" 2>/dev/null) || temp_now=
  cap_now=$(cat "$battCapacity" 2>/dev/null) || cap_now=
  case "$temp_now" in ''|*[!0-9]*) ;; *)
    if [ "$connected" = true ]; then
      if [ "$temp_now" -ge $(( ${temperature[1]} * 10 )) ]; then
        if [ "${ng_heat-normal}" != hot ]; then
          ng_emit hot 'Battery reached configured temperature limit' 'Bateria atingiu o limite de temperatura configurado'
        fi
        ng_heat=hot
      elif [ "$temp_now" -ge $(( ${temperature[0]} * 10 )) ]; then
        if [ "${ng_heat-normal}" = normal ]; then
          ng_emit warm 'Battery reached configured cooldown temperature' 'Bateria atingiu a temperatura de arrefecimento configurada'
          ng_heat=warm
        fi
      elif [ "$temp_now" -lt $(( ${temperature[0]} * 10 - 20 )) ]; then ng_heat=normal
      fi
    fi
  ;; esac
  case "$cap_now" in ''|*[!0-9]*) ;; *)
    if [ "$connected" = false ] && [ "$cap_now" -le 20 ] && [ "${ng_low-false}" = false ]; then
      ng_emit low "Battery low: ${cap_now}%" "Bateria fraca: ${cap_now}%"
      ng_low=true
    elif [ "$cap_now" -gt 25 ]; then ng_low=false
    fi
  ;; esac
  # Fixed vocabulary/numeric fields only; never source this file as shell code.
  printf 'connected=%s\nstate=%s\nreason=%s\npause=%s\nresume=%s\n' "$connected" "$state" "${ng_pause_reason-}" "${capacity[3]}" "${capacity[2]}" > "$TMPDIR/ng-state" || :
  return 0
}
