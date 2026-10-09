# usage: . $0
id=acc
# Calibration subshells inherit the daemon lock and can outlive their parent.
stop_daemon_holders() {
  local signal= pid= command=
  for signal in TERM KILL; do
    for pid in $(pgrep -f '/accd.sh' 2>/dev/null); do
      [ "$pid" != "$$" ] || continue
      command=$(tr '\000' ' ' < /proc/$pid/cmdline 2>/dev/null | sed 's|^/system/bin/sh |sh |; s/ *$//')
      case "$command" in
        "sh /data/adb/vr25/acc/accd.sh"|"sh /data/adb/vr25/acc/accd.sh "*|"sh /data/adb/modules/acc/accd.sh"|"sh /data/adb/modules/acc/accd.sh "*|"sh /dev/.vr25/acc/accd.sh"|"sh /dev/.vr25/acc/accd.sh "*) kill -$signal "$pid" 2>/dev/null || :;;
      esac
    done
    [ "$signal" != TERM ] || sleep 1
  done
}
stop_daemon_holders
mkdir -p "$TMPDIR"
timeout 5 flock "$TMPDIR/${id}.lock" true || return 1
