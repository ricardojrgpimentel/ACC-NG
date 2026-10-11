# All writers share a bounded mutex and publish a validated file by rename.
ng_write_config() (
  set +u
  if ! ${ng_config_locked:-false}; then
    exec 9>"$TMPDIR/.ng-config.lock" || return 1
    timeout 5 flock 0 <&9 || return 1
  fi
  ng_config_shell=/system/bin/sh
  [ -x "$ng_config_shell" ] || ng_config_shell=bash
  if ! ${ng_config_locked:-false} && [ -s "$config" ]; then
    "$ng_config_shell" -n "$config" || return 1
    . "$config" || return 1
  fi
  ng_config_new=$(mktemp "${config}.new.XXXXXX") || return 1
  trap 'rm -f "$ng_config_new" "$ng_config_new.scripts"' EXIT
  trap 'exit 1' HUP INT TERM
  ng_config_old=$config
  ng_config_words() {
    local word= first=true
    set -f
    for word in $1; do
      $first || printf ' '; first=false
      case "$word" in *[!a-zA-Z0-9_./:%+@=-]*) ng_quote_config "$word";; *) printf '%s' "$word";; esac
    done
  }
  ng_quote_config() { printf "'%s'" "$(printf '%s' "$1" | awk '{gsub(/\047/, "\047\042\047\042\047"); printf "%s%s", (NR > 1 ? "\n" : ""), $0}')"; }
set +u

ngn=${ng_notifications-${ngNotifications-true}}
ngl=${ng_notification_language-${ngNotificationLanguage-en}}
case "$ngn" in true|false) ;; *) ngn=true;; esac
case "$ngl" in pt|pt-PT|pt-BR|en) ;; *) ngl=en;; esac

ab="${apply_on_boot-${ab-${applyOnBoot[@]}}}"
af=${amp_factor-${af-$ampFactor}}
aiapc="${allow_idle_above_pcap-${aiapc-$allowIdleAbovePcap}}"
ap="${apply_on_plug-${ap-${applyOnPlug[@]}}}"
bso="${batt_status_override-${bso-$battStatusOverride}}"
bsw=${batt_status_workaround-${bsw-$battStatusWorkaround}}
cc=${cooldown_capacity-${cc-${capacity[1]}}}
cch=${cooldown_charge-${cch-${cooldownRatio[0]}}}
ccu="${cooldown_custom-${ccu-${cooldownCustom[@]}}}"
cdc=${cooldown_current-${cdc-$cooldownCurrent}}
cm=${capacity_mask-${cm-${capacity[5]}}}
cp=${cooldown_pause-${cp-${cooldownRatio[1]}}}
cs=${capacity_sync-${cs-${capacity[4]}}}
ct=${cooldown_temp-${ct-${temperature[0]}}}
cw=${current_workaround-${cw-$currentWorkaround}}
dp="${discharge_polarity-${dp-$dischargePolarity}}"
fo="${force_off-${fo-$forceOff}}"
it="${idle_threshold-${it-$idleThreshold}}"
l=${lang-${l-${language}}}
mcc="${max_charging_current-${mcc-${maxChargingCurrent[@]}}}"
mcv="${max_charging_voltage-${mcv-${maxChargingVoltage[@]}}}"
mt=${max_temp-${mt-${temperature[1]}}}
om="${off_mid-${om-$offMid}}"
pbim=${prioritize_batt_idle_mode-${pbim-$prioritizeBattIdleMode}}
pc=${pause_capacity-${pc-${capacity[3]}}}
rbsp=${reset_batt_stats_on_pause-${rbsp-${resetBattStats[0]}}}
rbspl=${reset_batt_stats_on_plug-${rbspl-${resetBattStats[2]}}}
rbsu=${reset_batt_stats_on_unplug-${rbsu-${resetBattStats[1]}}}
rc=${resume_capacity-${rc-${capacity[2]}}}
rcp="${run_cmd_on_pause-${rcp-${runCmdOnPause[@]}}}"
rr="${reboot_resume-${rr-$rebootResume}}"
rt=${resume_temp-${rt-${temperature[2]}}}
s="${charging_switch-${s-${chargingSwitch[@]}}}"
sc=${shutdown_capacity-${sc-${capacity[0]}}}
st=${shutdown_temp-${st-${temperature[3]}}}
tl="${temp_level-${tl-$tempLevel}}"
vf=${volt_factor-${vf-$voltFactor}}

# Reject malformed scalar values before arithmetic or shell serialization.
case "$sc" in -1|'') :;; *[!0-9]*) return 11;; esac
for ng_numeric in "$cc" "$rc" "$pc" "$cch" "$cp" "$ct" "$mt" "${rt%r}" "$st" "$it" "$tl"; do
  case "$ng_numeric" in *[!0-9]*) return 11;; esac
done
case "$dp" in ''|+|-) :;; *) return 11;; esac
case "$af" in ''|1000|1000000) :;; *) return 11;; esac
case "$vf" in ''|1000|1000000) :;; *) return 11;; esac
for ng_bool in "$ngn" "$aiapc" "$bsw" "$cm" "$cw" "$fo" "$om" "$rr" "$rbsp" "$rbspl" "$rbsu"; do
  case "$ng_bool" in ''|true|false) :;; *) return 11;; esac
done
case "$cs" in ''|auto|true|false) :;; *) return 11;; esac
case "$pbim" in ''|true|false|no) :;; *) return 11;; esac
case "$l" in ''|*[!a-zA-Z0-9_-]*) return 11;; esac
case "$cdc" in *[!0-9]*) return 11;; esac

# Keep percentage and voltage hysteresis in the same units.
if [ "${pc:-75}" -gt 3000 ]; then
  [ "${pc:-75}" -le 5000 ] && [ "${rc:-70}" -gt 3000 ] || return 11
else
  [ "${pc:-75}" -ge 1 ] && [ "${pc:-75}" -le 100 ] && [ "${rc:-70}" -le 100 ] || return 11
fi
rt=${rt:-45}
[ "${mt:-50}" -le 120 ] && [ "${rt%r}" -le "${mt:-50}" ] 2>/dev/null || return 11
[ "${st:-55}" -ge "${mt:-50}" ] && [ "${st:-55}" -le 120 ] || return 11

# backup scripts
touch "$ng_config_new.scripts"
grep '^:' $config > "$ng_config_new.scripts" 2>/dev/null || :
sed -i 's/^:/\n:/' "$ng_config_new.scripts"
printf "\n\n\n" >> "$ng_config_new.scripts"

# enforce valid pc and rc difference
[ $rc -lt $pc ] || {
  [ $pc -gt 3000 ] && rc=$((pc - 50)) || rc=$((pc - 5))
}


echo "configVerCode=$(cat $TMPDIR/.config-ver)

ngNotifications=$ngn
ngNotificationLanguage=$ngl
allowIdleAbovePcap=${aiapc:-true}
ampFactor=$af
battStatusWorkaround=${bsw:-true}
capacity=(${sc:-5} ${cc:-50} ${rc:-70} ${pc:-75} ${cs:-false} ${cm:-false})
cooldownCurrent=$cdc
cooldownRatio=($cch $cp)
currentWorkaround=${cw:-false}
dischargePolarity=$dp
forceOff=${fo:-false}
idleThreshold=${it:-40}
language=${l:-en}
offMid=${om:-true}
prioritizeBattIdleMode=${pbim:-true}
rebootResume=${rr:-false}
resetBattStats=(${rbsp:-false} ${rbsu:-false} ${rbspl:-false})
temperature=(${ct:-35} ${mt:-50} ${rt:-45} ${st:-55})
tempLevel=${tl:-0}
voltFactor=$vf

applyOnBoot=($(ng_config_words "$ab"))

applyOnPlug=($(ng_config_words "$ap"))

battStatusOverride=$(ng_quote_config "$bso")

chargingSwitch=($(ng_config_words "$(echo "$s" | sed 's/ m[AV]//')"))

cooldownCustom=($(ng_config_words "$ccu"))

maxChargingCurrent=($(ng_config_words "$mcc"))

maxChargingVoltage=($(ng_config_words "$mcv"))

runCmdOnPause=$(ng_quote_config "$rcp")" > "$ng_config_new"


cat "$ng_config_new.scripts" "$TMPDIR/.config-help" >> "$ng_config_new" || return 1
# Preserve extension keys; generated standard keys take precedence.
awk -F= 'FNR==NR { if ($0 ~ /^[a-zA-Z_][a-zA-Z_0-9]*=/) known[$1]=1; next }
  /^[a-zA-Z_][a-zA-Z_0-9]*=/ { if (!known[$1]) print }' "$ng_config_new" "$ng_config_old" >> "$ng_config_new.extensions"
cat "$ng_config_new.extensions" >> "$ng_config_new"
rm -f "$ng_config_new.extensions"
"$ng_config_shell" -n "$ng_config_new" || return 1
[ ! -s "$ng_config_old" ] || { cp -p "$ng_config_old" "${config}.last-good.new" && mv "${config}.last-good.new" "${config}.last-good"; } || return 1
chmod 0600 "$ng_config_new" || return 1
mv -f "$ng_config_new" "$config" || return 1
)
ng_write_config
