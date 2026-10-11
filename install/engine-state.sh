# Boot-aware readiness; read-only status stays fast during initialization.
ng_engine_state() {
  mkdir -p "$dataDir"
  local boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) state=$1
  if [ "$(sed -n 's/^bootId=//p' "$dataDir/engine-state" 2>/dev/null)" = "$boot" ] &&
    [ "$(sed -n 's/^engineState=//p' "$dataDir/engine-state" 2>/dev/null)" = "$state" ] &&
    [ "$(sed -n 's/^pid=//p' "$dataDir/engine-state" 2>/dev/null)" = "$$" ]; then return 0; fi
  printf 'engineState=%s\nbootId=%s\npid=%s\n' "$state" "$boot" "$$" > "$dataDir/engine-state.$$" &&
    mv "$dataDir/engine-state.$$" "$dataDir/engine-state"
}
ng_print_engine_state() {
  local boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) saved= state=stopped
  saved=$(sed -n 's/^bootId=//p' "$dataDir/engine-state" 2>/dev/null)
  [ "$saved" != "$boot" ] || state=$(sed -n 's/^engineState=//p' "$dataDir/engine-state" 2>/dev/null)
  [ ! -f "$execDir/disable" ] || state=disabled
  [ ! -f "$TMPDIR/.test-active" ] || state=testing
  printf 'engineStateVersion=1\nengineState=%s\nrootManager=%s\n' "${state:-stopped}" "$(cat "$execDir/root-manager" 2>/dev/null || echo unknown)"
}
ng_wait_boot() {
  local elapsed=0
  ng_engine_state boot-wait
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; do
    [ ! -f "$execDir/disable" ] || { ng_engine_state disabled; return 14; }
    [ "$elapsed" -lt 300 ] || { ng_engine_state boot-timeout; return 16; }
    sleep 2; elapsed=$((elapsed + 2))
  done
  [ ! -f "$execDir/disable" ] || { ng_engine_state disabled; return 14; }
}
