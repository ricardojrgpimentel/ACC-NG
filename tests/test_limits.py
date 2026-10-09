"""Execute production limit routines against files, never live sysfs."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LimitTests(unittest.TestCase):
    def run_shell(self, commands):
        with tempfile.TemporaryDirectory() as td:
            fixture = Path(td)
            script = '''set -eu
mkdir -p battery logs
TMPDIR=$PWD; dataDir=$PWD
verbose=true; isAccd=true; tempLevel=0
applyOnBoot=(); applyOnPlug=(); maxChargingCurrent=(); maxChargingVoltage=()
oppositeValue=
tt() { case "$1" in *--exit*) return 0;; *) return 1;; esac; }
usleep() { :; }
not_charging() { return 1; }
print_volt_set() { :; }; print_volt_restored() { :; }
print_curr_set() { :; }; print_curr_restored() { :; }
'''
            # Only function definitions: do not initialise the actual ACC module.
            misc = (ROOT / 'install/misc-functions.sh').read_text().split('# environment')[0]
            misc = misc.replace('. $execDir/limit-control.sh', (ROOT / 'install/limit-control.sh').read_text())
            batt = (ROOT / 'install/batt-interface.sh').read_text().split('if ${init:-false}; then')[0]
            script += misc + batt
            script += (ROOT / 'install/set-ch-curr.sh').read_text()
            script += (ROOT / 'install/set-ch-volt.sh').read_text()
            script += commands
            serial = os.environ.get('ACC_TEST_ADB_SERIAL')
            if serial:
                # adb fixture runner is opt-in; all nodes/locks/logs are under mktemp.
                remote = subprocess.check_output(
                    ['adb', '-s', serial, 'shell', 'mktemp -d /data/local/tmp/acc-limit-test.XXXXXX'],
                    text=True).strip()
                path = fixture / 'test.sh'
                path.write_text('PATH=/dev/.vr25/busybox:$PATH\ncd ' + shlex.quote(remote) + '\n' + script)
                try:
                    subprocess.run(['adb', '-s', serial, 'push', str(path), remote + '/test.sh'],
                                   check=True, capture_output=True, text=True)
                    remote_cmd = '/system/bin/sh ' + shlex.quote(remote + '/test.sh')
                    result = subprocess.run(['adb', '-s', serial, 'shell', 'su -c ' +
                                             shlex.quote(remote_cmd)],
                                            capture_output=True, text=True, timeout=20)
                finally:
                    subprocess.run(['adb', '-s', serial, 'shell', 'su -c ' +
                                    shlex.quote('rm -rf ' + shlex.quote(remote))],
                                   check=True, capture_output=True)
            else:
                # macOS lacks flock/timeout and uses a different stat/sed CLI.
                # Android runs the real BusyBox tools, including the lock tests.
                shims = '''flock() { :; }; timeout() { shift; "$@"; }
sed() { if [ "$1" = -i ] && [ "$(uname)" = Darwin ]; then shift; command sed -i '' "$@"; else command sed "$@"; fi; }
stat() { if [ "$(uname)" = Darwin ]; then [ "$1" != -L ] || shift; if [ "$1" = -c ]; then shift 2; command stat -L -f %Lp "$1"; else command stat "$@"; fi; else command stat "$@"; fi; }
'''
                result = subprocess.run(['bash', '-c', shims + script], cwd=td,
                                        capture_output=True, text=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            return result.stdout.splitlines()

    def test_default_without_ownership_never_discovers_or_writes(self):
        self.assertEqual(['1800:4200:75'], self.run_shell('''
echo 1800 > battery/current; echo 4200 > battery/voltage; echo 75 > battery/siop_level
not_charging() { echo UNEXPECTED_DISCOVERY; exit 99; }
maxChargingCurrent=(500 battery/current::500::1800)
maxChargingVoltage=(4000 battery/voltage::4000::4200)
set_ch_curr -; set_ch_volt -; set_temp_level 0
apply_on_boot default; apply_on_plug default
echo "$(cat battery/current):$(cat battery/voltage):$(cat battery/siop_level)"
test ! -e .mcc-custom; test ! -e .volt-custom; test ! -e .tl-custom
'''))

    def test_current_changes_do_not_apply_voltage_or_user_scripts(self):
        self.assertEqual(['500:4200:9', '1800:4200:9'], self.run_shell('''
echo 1800 > battery/current; echo 4200 > battery/voltage; echo 9 > battery/script
echo battery/current::v::1800 > ch-curr-ctrl-files; touch .ch-curr-read
maxChargingVoltage=(4000 battery/voltage::4000::4200)
applyOnPlug=(battery/script::1::0)
set_ch_curr 500
echo "$(cat battery/current):$(cat battery/voltage):$(cat battery/script)"
set_ch_curr -
echo "$(cat battery/current):$(cat battery/voltage):$(cat battery/script)"
'''))

    def test_voltage_changes_do_not_apply_boot_scripts(self):
        self.assertEqual(['4000:9', '4200:9'], self.run_shell('''
echo 4200 > battery/voltage; echo 9 > battery/script
echo battery/voltage::v::4200 > ch-volt-ctrl-files
applyOnBoot=(battery/script::1::0)
set_ch_volt 4000
echo "$(cat battery/voltage):$(cat battery/script)"
set_ch_volt -
echo "$(cat battery/voltage):$(cat battery/script)"
'''))

    def test_repeat_and_restart_preserve_first_real_default(self):
        self.assertEqual(['1800', '1200'], self.run_shell('''
echo 1800 > battery/current
apply_limit current value battery/current::500::9999
apply_limit current value battery/current::600::500
# The cached/config default is deliberately wrong after the restart.
maxChargingCurrent=(600 battery/current::600::600)
apply_on_plug
apply_limit current default
cat battery/current
echo 1200 > battery/current
apply_limit current default
cat battery/current
'''))

    def test_thermal_reset_restores_oem_value_once(self):
        self.assertEqual(['50', '75', '60'], self.run_shell('''
echo 75 > battery/siop_level
set_temp_level 50; cat battery/siop_level
set_temp_level 25
set_temp_level 0; cat battery/siop_level
echo 60 > battery/siop_level
set_temp_level 0; cat battery/siop_level
'''))

    def test_thermal_levels_and_invalid_input(self):
        self.assertEqual(['5', '3', 'INVALID'], self.run_shell('''
echo 10 > battery/num_system_temp_levels; echo 3 > battery/system_temp_level
set_temp_level 50; cat battery/system_temp_level
set_temp_level 0; cat battery/system_temp_level
if set_temp_level 101; then exit 99; else test "$?" = 11; echo INVALID; fi
'''))

    def test_failed_writes_do_not_claim_ownership(self):
        self.assertEqual(['1800'], self.run_shell('''
echo 1800 > battery/current
write_control() { return 1; }
if apply_limit current value battery/current::500::1800; then exit 99; fi
test ! -e .mcc-custom
cat battery/current
'''))

    def test_interrupted_write_keeps_snapshot_for_recovery(self):
        self.assertEqual(['battery/current::1800', '1800'], self.run_shell('''
echo 1800 > battery/current
write() { echo "$1" > "$2"; exit 23; }
if apply_limit current value battery/current::500::1800; then exit 99; else test "$?" = 23; fi
cat .mcc-custom
write() { echo "$1" > "$2"; }
apply_limit current default; cat battery/current
'''))

    def test_read_current_does_not_wait_for_discovery(self):
        self.assertEqual(['500'], self.run_shell('''
not_charging() { exit 99; }
maxChargingCurrent=(500)
set_ch_curr
'''))

    def test_partial_failure_keeps_only_changed_nodes_for_retry(self):
        self.assertEqual(['battery/a::1800', '1800:1200'], self.run_shell('''
echo 1800 > battery/a; echo 1200 > battery/b
write_control() { test "$2" != battery/b || return 1; echo "$1" > "$2"; }
if apply_limit current value battery/a::500::1800 battery/b::500::1200; then exit 99; fi
cat .mcc-custom
apply_limit current default
echo "$(cat battery/a):$(cat battery/b)"
test ! -e .mcc-custom
'''))

    def test_failed_reset_retains_snapshot_for_next_attempt(self):
        self.assertEqual(['battery/current::1800', '1800'], self.run_shell('''
echo 1800 > battery/current
apply_limit current value battery/current::500::1800
write_control() { return 1; }
if apply_limit current default; then exit 99; fi
cat .mcc-custom
write_control() { echo "$1" > "$2"; }
apply_limit current default; cat battery/current
test ! -e .mcc-custom
'''))

    def test_refused_readback_is_failure_and_remains_recoverable(self):
        self.assertEqual(['battery/current::1800', '1800'], self.run_shell('''
echo 1800 > battery/current
write() { echo 700 > "$2"; return 0; }
if apply_limit current value battery/current::500::1800; then exit 99; fi
cat .mcc-custom
write() { echo "$1" > "$2"; }
apply_limit current default; cat battery/current
'''))

    def test_permissions_and_owner_survive_success_and_fallback(self):
        self.assertEqual(['640:500', '640:600'], self.run_shell('''
echo 1800 > battery/current; chmod 640 battery/current
before=$(ls -ln battery/current | awk '{print $3 ":" $4}')
write_control 500 battery/current
test "$(ls -ln battery/current | awk '{print $3 ":" $4}')" = "$before"
echo "$(stat -c %a battery/current):$(cat battery/current)"
# Simulate a first refused write to exercise the temporary u+w path.
calls=0
printf() { calls=$((calls + 1)); test "$calls" -ne 1 || return 1; command printf "$@"; }
write_control 600 battery/current
test "$(ls -ln battery/current | awk '{print $3 ":" $4}')" = "$before"
echo "$(stat -c %a battery/current):$(cat battery/current)"
'''))

    def test_permission_restore_failure_is_reported(self):
        self.assertEqual(['RESTORE_FAILED'], self.run_shell('''
echo 1800 > battery/current; chmod 640 battery/current
calls=0
printf() { calls=$((calls + 1)); test "$calls" -ne 1 || return 1; command printf "$@"; }
chmod() { test "$1" != 640 || return 1; command chmod "$@"; }
if write_control 500 battery/current; then exit 99; else echo RESTORE_FAILED; fi
'''))

    def test_symlink_fallback_restores_target_permissions(self):
        self.assertEqual(['640:600'], self.run_shell('''
echo 1800 > battery/current; chmod 640 battery/current
ln -s current battery/current-link
calls=0
printf() { calls=$((calls + 1)); test "$calls" -ne 1 || return 1; command printf "$@"; }
write_control 600 battery/current-link
echo "$(stat -c %a battery/current):$(cat battery/current)"
'''))

    def test_busy_lock_does_not_touch_controls(self):
        self.assertEqual(['1800'], self.run_shell('''
echo 1800 > battery/current
timeout() { return 124; }
if apply_limit current value battery/current::500::1800; then exit 99; fi
cat battery/current; test ! -e .mcc-custom
'''))

    def test_helpers_do_not_run_the_daemon_exit_trap(self):
        self.assertEqual(['1800'], self.run_shell('''
echo 1800 > battery/current
trap 'echo UNEXPECTED_CLEANUP >> "$TMPDIR/exits"' EXIT
write_control 1800 battery/current
apply_limit current value battery/current::500::1800
apply_limit current default
test ! -e exits
trap - EXIT
cat battery/current
'''))

    @unittest.skipUnless(os.environ.get('ACC_TEST_ADB_SERIAL'), 'real flock requires Android')
    def test_concurrent_applications_share_the_original_snapshot(self):
        self.assertEqual(['1800'], self.run_shell('''
echo 1800 > battery/current
write() { echo "$1" > "$2"; if [ "$1" = 500 ]; then touch first-writing; sleep 1; fi; }
apply_limit current value battery/current::500::1800 &
first=$!
for attempt in $(seq 50); do test ! -f first-writing || break; sleep 0.1; done
test -f first-writing
apply_limit current value battery/current::600::1800
wait "$first"
apply_limit current default
cat battery/current
'''))

    @unittest.skipUnless(os.environ.get('ACC_TEST_ADB_SERIAL'), 'real timeout requires Android')
    def test_real_lock_contention_has_a_five_second_budget(self):
        self.assertEqual(['1800'], self.run_shell('''
echo 1800 > battery/current
flock "$TMPDIR/.mcc-custom.lock" /system/bin/sh -c 'touch lock-held; sleep 7' &
holder=$!
for attempt in $(seq 50); do test ! -f lock-held || break; sleep 0.1; done
test -f lock-held
started=$(date +%s)
if apply_limit current value battery/current::500::1800; then exit 99; fi
elapsed=$(( $(date +%s) - started ))
test "$elapsed" -ge 4; test "$elapsed" -le 6
wait "$holder"
cat battery/current; test ! -e .mcc-custom
'''))

    def test_store_mode_is_excluded_from_auto_candidates(self):
        source = (ROOT / 'install/ctrl-files.sh').read_text()
        self.assertNotIn('battery/store_mode 0 1', [line for line in source.splitlines() if not line.startswith('#')])
