# Bounded, serialized diagnostic export. Copies prevent unbounded symlink targets.
ng_export_logs() (
  trap - EXIT HUP INT TERM
  local work= file= count=0 output=$dataDir/logs/acc-logs-$device.tgz
  mkdir -p "$dataDir/logs"
  exec 8>"$TMPDIR/.ng-log-export.lock" || return 1
  flock -n 0 <&8 || return 16
  work=$(mktemp -d "$TMPDIR/.ng-diagnostics.XXXXXX") || return 1
  trap 'rm -rf "$work"' EXIT
  trap 'exit 1' HUP INT TERM
  for file in "$dataDir"/logs/*.log "$dataDir"/logs/*.txt "$TMPDIR"/*.log "$TMPDIR"/ch-switches \
    "$TMPDIR"/working-switches "$dataDir"/logs/switch-restore-pending "$TMPDIR"/ch-curr-ctrl-files "$TMPDIR"/ch-volt-ctrl-files; do
    [ -f "$file" ] || continue
    [ "$count" -lt 40 ] || break
    tail -c 131072 "$file" > "$work/${count}-${file##*/}.txt"
    count=$((count + 1))
  done
  tail -c 131072 "$config" > "$work/config.txt"
  . "$execDir/engine-state.sh"
  ng_print_engine_state > "$work/engine-state.txt"
  ng_print_sensor_status > "$work/sensors.txt" 2>&1 || :
  ng_print_power_limits > "$work/limits.txt" 2>&1 || :
  timeout 3 dmesg 2>&1 | tail -c 131072 > "$work/kernel.txt" || :
  timeout 3 logcat -d -t 400 2>&1 | tail -c 131072 > "$work/logcat.txt" || :
  timeout 5 dumpsys battery > "$work/dumpsys-battery.txt" 2>&1 || :
  (cd "$work" && timeout 8 tar -czf "$output.new" .) || return 1
  mv "$output.new" "$output" || return 1
  cp "$output" /sdcard/Download/ 2>/dev/null || :
  echo "$output"
)
