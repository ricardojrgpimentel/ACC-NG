"""Exercise bounded probes against file-backed controls, never live sysfs."""
import unittest
from contract_cases import run, source, function
from test_engine import function as daemon_function


class SwitchTests(unittest.TestCase):
    def probe_script(self, commands):
        script = source('switch-test.sh') + '\n' + function('misc-functions.sh', 'parse_value') + '''
mkdir -p battery logs
printf '1\n' > battery/enable
printf 'Charging\n' > state
printf '0\n' > clock
echo 300 > temperature
temp=$PWD/temperature; temperature=(35 50 40r 55)
ng_test_time() { cat clock; }
sleep() { echo $(( $(cat clock) + $1 )) > clock; }
write_control() { printf '%s\n' "$1" > "$2"; }
flip_sw() {
  case "$1" in off) echo 0 > battery/enable; echo "$offStatus" > state;;
    on) echo 1 > battery/enable; echo Charging > state;; esac
}
not_charging() { _status=$(cat state); [ "$_status" != Charging ]; }
print_switch_works() { echo WORKS; }
ng_power_state() { return 0; }
ng_telemetry_valid() { return 0; }
cat > acca <<'SH'
#!/system/bin/sh
exit 9
SH
chmod +x acca
# The fixture wrapper uses the selected shell on host too.
''' + ('sed -i \'1c#!/bin/sh\' acca\n' if not __import__('os').environ.get('ACC_TEST_ADB_SERIAL') else '')
        return script + commands

    def probe(self, commands):
        return run(self.probe_script(commands))

    def test_term_restores_controls_and_clears_owned_flags(self):
        import os, shlex
        shell = '/system/bin/sh' if os.environ.get('ACC_TEST_ADB_SERIAL') else 'bash'
        runner = 'TMPDIR=$PWD; dataDir=$PWD; config=$PWD/config.txt\n' + self.probe_script('''offStatus=Idle
sleep() { kill -TERM "$$"; }
ng_test_command battery/enable 1 0
''')
        result = run('printf %s ' + shlex.quote(runner) + ' > runner.sh\n' + shell + ''' runner.sh || code=$?
echo "${code:-0}:$(cat battery/enable)"
test ! -e .test-active
grep -Fx result=16 logs/last-switch-test.log
''')
        self.assertEqual({'code': 0, 'output': '16:1\nresult=16'}, result)

    def test_idle_result_requires_three_samples_each_phase_and_restores(self):
        result = self.probe('''offStatus=Idle
(ng_test_command battery/enable 1 0) || code=$?
echo "CODE:${code:-0}:$(cat battery/enable):$(cat clock)"
test ! -e .test-active
''')
        self.assertEqual(0, result['code'])
        self.assertIn('- battIdleMode=true', result['output'])
        self.assertIn('CODE:15:1:4', result['output'])

    def test_quiet_preserves_idle_and_failure_codes(self):
        for status, code, text in [('Idle', 15, 'Idle'), ('Charging', 10, 'Fail'), ('Unknown', 16, 'Fail')]:
            with self.subTest(status=status):
                self.assertEqual({'code': 0, 'output': f'{text}\n{code}:1'}, self.probe(f'''offStatus={status}
(ng_test_command q battery/enable 1 0) || code=$?
echo "${{code:-0}}:$(cat battery/enable)"
'''))

    def test_transient_idle_is_not_confirmed(self):
        result = self.probe('''offStatus=Idle
n=0
not_charging() { n=$((n + 1)); [ "$n" = 1 ] && _status=Idle || _status=Charging; [ "$_status" != Charging ]; }
(ng_test_command q battery/enable 1 0) || code=$?
echo "${code:-0}:$(cat battery/enable)"
''')
        self.assertEqual({'code': 0, 'output': 'Fail\n10:1'}, result)

    def test_deadline_and_cancel_restore_changed_values(self):
        for stop in ['echo 45 > clock', 'touch .test-cancel']:
            with self.subTest(stop=stop):
                self.assertEqual({'code': 0, 'output': 'Fail\n16:1'}, self.probe('''offStatus=Idle
sleep() { ''' + stop + '''; }
(ng_test_command q battery/enable 1 0) || code=$?
echo "${code:-0}:$(cat battery/enable)"
'''))

    def test_busy_probe_does_not_write_or_stop_daemon(self):
        self.assertEqual({'code': 0, 'output': 'Switch test busy\n16:1'}, self.probe('''offStatus=Idle
flock() { return 1; }
(ng_test_command battery/enable 1 0) || code=$?
echo "${code:-0}:$(cat battery/enable)"
'''))

    def test_offline_does_not_probe(self):
        self.assertEqual({'code': 0, 'output': '2:1'}, self.probe('''ng_power_state() { return 1; }
(ng_test_command battery/enable 1 0) || code=$?
echo "${code:-0}:$(cat battery/enable)"
'''))

    def test_missing_reference_is_an_error_without_permission_change(self):
        self.assertEqual({'code': 0, 'output': 'Fail\n10:1'}, self.probe('''offStatus=Idle
chmod() { exit 99; }
(ng_test_command q battery/enable battery/missing 0) || code=$?
echo "${code:-0}:$(cat battery/enable)"
'''))

    def test_restore_failure_is_reported_as_hardware_failure(self):
        self.assertEqual({'code': 0, 'output': 'Fail\n7:0'}, self.probe('''offStatus=Unknown
write_control() { return 1; }
(ng_test_command q battery/enable 1 0) || code=$?
echo "${code:-0}:$(cat battery/enable)"
'''))

    def test_full_group_snapshot_precedes_alias_writes(self):
        self.assertEqual({'code': 0, 'output': 'Idle\n15:1:2'}, self.probe('''offStatus=Idle
echo 2 > battery/other
flip_sw() {
 if [ "$1" = off ]; then echo 0 > battery/enable; echo 0 > battery/other; echo Idle > state;
 else echo 1 > battery/enable; echo 1 > battery/other; echo Charging > state; fi
}
(ng_test_command q battery/enable 1 0 battery/other 2 0) || code=$?
echo "${code:-0}:$(cat battery/enable):$(cat battery/other)"
'''))

    def test_polarity_learns_only_consistent_physical_discharge_without_wait(self):
        script = source('sensor-discovery.sh') + '\n' + daemon_function('set_dp') + '''
src_cfg() { :; }; ng_power_state() { return "$fixturePower"; }
TMPDIR=$PWD; currFile=$PWD/current
currentIsBattery=true; battStatusWorkaround=true; idleThreshold=40; ampFactor_=1000000
fixturePower=1; echo -500000 > current
cat > acca <<'SH'
#!/system/bin/sh
printf '%s\n' "$*" >> learnt
SH
chmod +x acca
'''
        if not __import__('os').environ.get('ACC_TEST_ADB_SERIAL'):
            script += 'sed -i \'1c#!/bin/sh\' acca\n'
        result = run(script + '''set_dp; set_dp; test ! -e learnt
fixturePower=2; set_dp; fixturePower=1; set_dp; set_dp; test ! -e learnt
set_dp; cat learnt
# Explicit polarity is preserved.
dischargePolarity=+; set_dp; test "$(wc -l < learnt)" -eq 1
''')
        self.assertEqual({'code': 0, 'output': '--set discharge_polarity=-'}, result)

    def test_r_suffix_only_relaxes_thermal_pause_and_never_capacity_pause(self):
        script = ''.join(daemon_function(n) + '\n' for n in ['_lt_pause_cap', '_le_resume_cap']) + '''
t() { test "$@"; }; tt() { case "$1" in *r) return 0;; *) return 1;; esac; }
echo 55 > cap; battCapacity=$PWD/cap; capacity=(2 101 50 60 false false); temperature=(35 50 40r 55)
ng_pause_reason=limit
if _le_resume_cap; then exit 99; fi
ng_pause_reason=temperature; _le_resume_cap; echo THERMAL_ONLY
'''
        self.assertEqual({'code': 0, 'output': 'THERMAL_ONLY'}, run(script))

    def test_cooldown_pause_observes_shutdown_and_unplug_within_one_second(self):
        for power, temp, expected in [(1, 300, '1'), (0, 550, 'SHUTDOWN\n1'), (0, 510, '1')]:
            script = daemon_function('ng_cooldown_wait') + f'''
echo {temp} > temp; temp=$PWD/temp; temperature=(35 50 40r 55)
src_cfg() {{ :; }}; ng_telemetry_valid() {{ return 0; }}; _lt_pause_cap() {{ return 0; }}
ng_power_state() {{ return {power}; }}; shutdown() {{ echo SHUTDOWN; }}
n=0; sleep() {{ n=$((n + 1)); }}
ng_cooldown_wait 60 || :; echo "$n"
'''
            self.assertEqual({'code': 0, 'output': expected}, run(script))
