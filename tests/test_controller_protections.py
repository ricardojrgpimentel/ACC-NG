"""Controller effects and deadlines with synthetic sensors/platform operations."""
import unittest

from contract_cases import function, run, source
from test_engine import function as daemon_function


class ControllerProtectionTests(unittest.TestCase):
    def controller(self, commands):
        script = source('default-config.txt') + '\n'
        script += function('misc-functions.sh', 'tt') + '\n'
        script += ''.join(daemon_function(name) + '\n' for name in [
            '_ge_cooldown_cap', '_ge_pause_cap', '_lt_pause_cap',
            '_gt_pause_margin', '_gt_resume_cap', '_le_resume_cap',
            '_le_shutdown_cap', 'temp_ok', 'below_abs_lims',
            'ng_cooldown_wait', 'ng_disable_safe', 'ctrl_charging'])
        script += '''
execDir=$PWD; mkdir logs; touch "$config"
echo 55 > capacity; battCapacity=$PWD/capacity
echo 300 > sensor-temp; temp=$PWD/sensor-temp
echo 3900 > voltage
capacity=(5 50 50 60 false false); temperature=(35 50 45 55)
loopDelay=(3 9); offMid=false; allowIdleAbovePcap=true
resetBattStats=(false false false); shutdownWarnings=false
cooldown=false; cooldownCurrent=; cooldownCustom=(); cooldownRatio=()
capacitySync=false; switch_state=on; fixture_power=0; telemetry=true; chgStatusCode=2
ng_pause_reason=; clock=0; ticks=0
t() { test "$@"; }; volt_now() { cat voltage; }
src_cfg() { :; }; ng_engine_state() { :; }; ng_observe() { :; }
ng_telemetry_valid() { $telemetry; }
ng_power_state() { return "$fixture_power"; }
is_charging() { [ "$fixture_power" != 1 ] && [ "$switch_state" = on ]; }
not_charging() { _status=Discharging; return 0; }
disable_charging() { switch_state=off; echo OFF; }
enable_charging() { switch_state=on; echo ON; }
flip_sw() { switch_state=off; echo OFF; }
force_off() { echo HOLD_OFF; }
shutdown() { echo SHUTDOWN; }
cmd_batt() { :; }; _uptime() { return 1; }
notif() { :; }
'''
        return run(script + commands)

    def cooldown_boundary(self, mutation):
        return self.controller('''
cooldownRatio=(60 1)
sleep() {
  if [ "$1" = 9 ]; then
    printf 'reason=%s clock=%s ticks=%s\n' "$ng_pause_reason" "$clock" "$ticks"
    exit 0
  fi
  clock=$((clock + $1))
  if [ "$1" = 1 ]; then
    ticks=$((ticks + 1))
    [ "$ticks" -le 4 ] || { echo WAIT_OVERRUN; exit 77; }
    # First second is the OFF pause. Change a sensor at the first ON sample.
    if [ "$ticks" = 2 ]; then
''' + mutation + '''
    fi
  fi
}
ctrl_charging
''')

    def test_cooldown_charge_interrupts_at_capacity_or_max_temperature(self):
        for mutation, reason in [('echo 60 > capacity', 'limit'),
                                 ('echo 500 > sensor-temp', 'temperature')]:
            with self.subTest(reason=reason):
                self.assertEqual({'code': 0, 'output':
                    f'OFF\nON\nOFF\nHOLD_OFF\nreason={reason} clock=5 ticks=2'},
                    self.cooldown_boundary(mutation))

    def test_cooldown_charge_interrupts_for_shutdown_or_unplug(self):
        self.assertEqual({'code': 0, 'output':
            'OFF\nON\nSHUTDOWN\nOFF\nHOLD_OFF\nreason=temperature clock=5 ticks=2'},
            self.cooldown_boundary('echo 550 > sensor-temp'))
        self.assertEqual({'code': 0, 'output':
            'OFF\nON\nreason= clock=5 ticks=2'},
            self.cooldown_boundary('fixture_power=1'))

    def test_cooldown_charge_interrupts_when_protective_data_becomes_invalid(self):
        for mutation, expected in [
                ('telemetry=false', 'OFF\nON\nOFF\nreason=sensor clock=5 ticks=2'),
                ('touch .config-invalid', 'OFF\nON\nOFF\nOFF\nreason= clock=6 ticks=3')]:
            with self.subTest(mutation=mutation):
                self.assertEqual({'code': 0, 'output':
                    expected},
                    self.cooldown_boundary(mutation))

    def test_shutdown_uses_physical_percent_or_voltage_after_discharge_check(self):
        for shutdown_limit, level, voltage, should_shutdown in [
                (5, 5, 3900, True), (5, 6, 3900, False),
                (3500, 80, 3500, True), (3500, 1, 3501, False)]:
            with self.subTest(shutdown_limit=shutdown_limit, level=level, voltage=voltage):
                result = self.controller(f'''
capacity=( {shutdown_limit} 101 50 60 true true )
echo {level} > capacity; echo {voltage} > voltage; fixture_power=1
_uptime() {{ return 0; }}
sleep() {{ ticks=$((ticks + 1)); [ "$ticks" -lt 2 ] || exit 0; }}
ctrl_charging
''')
                self.assertEqual({'code': 0, 'output': 'SHUTDOWN' if should_shutdown else ''}, result)

    def test_reconnect_during_shutdown_delay_prevents_shutdown(self):
        self.assertEqual({'code': 0, 'output': ''}, self.controller('''
echo 5 > capacity; fixture_power=1; _uptime() { return 0; }
not_charging() { [ "$fixture_power" = 1 ]; }
sleep() { ticks=$((ticks + 1)); fixture_power=0; [ "$ticks" -lt 2 ] || exit 0; }
ctrl_charging
'''))

    def test_failed_disable_has_three_attempts_and_a_bounded_error(self):
        self.assertEqual({'code': 0, 'output':
            'code=7 attempts=3 clock=2\ncontrol-failure attempts=3'}, self.controller('''
echo 60 > capacity; attempts=0
disable_charging() { attempts=$((attempts + 1)); return 1; }
sleep() { clock=$((clock + $1)); }
ctrl_charging || code=$?
printf 'code=%s attempts=%s clock=%s\n' "${code:-0}" "$attempts" "$clock"
sed 's/^[0-9]* //' logs/ng-recovery.log
'''))

    def test_unexpected_idle_reselection_is_limited_before_control_failure(self):
        self.assertEqual({'code': 0, 'output': 'code=7 cycles=2 attempts=3'}, self.controller('''
echo 61 > capacity; allowIdleAbovePcap=false; attempts=0
cycle_switches_off() { echo CYCLE >> cycles; }
force_off() { :; }
disable_charging() { attempts=$((attempts + 1)); return 1; }
sleep() { :; }
ctrl_charging || code=$?
printf 'code=%s cycles=%s attempts=%s\n' "${code:-0}" "$(wc -l < cycles | tr -d ' ')" "$attempts"
'''))
