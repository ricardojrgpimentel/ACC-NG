import pathlib, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON = (ROOT/'install/accd.sh').read_text()

def function(name):
    start = DAEMON.index('  '+name+'() {')
    end = DAEMON.index('\n  }', start) + len('\n  }')
    return DAEMON[start:end]

class EngineTests(unittest.TestCase):
    def run_shell(self, script):
        result = subprocess.run(['bash', '-eu', '-c', script], capture_output=True, text=True, timeout=5)
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout.splitlines()

    def control(self, charging, level=65, temperature=300, pause=60, resume=50):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);(p/'cap').write_text(str(level));(p/'temp').write_text(str(temperature))
            script=f'TMPDIR={td}; battCapacity={td}/cap; temp={td}/temp; capacity=(2 101 {resume} {pause} false false); temperature=(35 50 45 55); loopDelay=(1 1); offMid=false; allowIdleAbovePcap=true; resetBattStats=(false false false); cooldownRatio=(); cooldownCustom=(); cooldown=false\n'
            script+='t() { test "$@"; }; tt() { return 1; }; volt_now() { echo 3900; }; ng_observe() { return 0; }; force_off() { :; }; disable_charging() { echo OFF; }; enable_charging() { echo ON; }; sleep() { exit 0; }; _uptime() { return 1; }; not_charging() { return 1; }; is_charging() { '+('return 0' if charging else 'return 1')+'; };\n'
            for n in ['_ge_pause_cap','_lt_pause_cap','_gt_resume_cap','_le_resume_cap','temp_ok','ctrl_charging']: script+=function(n)+'\n'
            return self.run_shell(script+'ctrl_charging')

    def test_profile_limits_are_not_fixed_90_80(self):
        self.assertEqual(['OFF'], self.control(True,level=65,pause=60,resume=50))
        self.assertEqual(['ON'], self.control(False,level=49,pause=60,resume=50))
        self.assertEqual([], self.control(False,level=55,pause=60,resume=50))
        self.assertEqual(['OFF'], self.control(True,level=75,pause=75,resume=70))

    def test_temperature_pauses_and_blocks_resume(self):
        self.assertEqual(['OFF'], self.control(True,level=30,temperature=510))
        self.assertEqual([], self.control(False,level=30,temperature=480))
        self.assertEqual(['ON'], self.control(False,level=30,temperature=440))

    def events(self, commands):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);(p/'battery').mkdir();(p/'usb').mkdir();(p/'bms').mkdir()
            (p/'battery/cap').write_text('60');(p/'battery/temp').write_text('300')
            script=f'cd {td}; TMPDIR={td}; dataDir={td}; battCapacity=battery/cap; temp=battery/temp; capacity=(2 101 50 60 false false); temperature=(35 50 45 55)\n'
            script+=f'. {ROOT}/install/ng-events.sh\nng_emit() {{ echo "$1:$2"; }}\n'+commands
            return self.run_shell(script)

    def test_pause_is_not_an_unplug_and_idle_uses_state(self):
        out=self.events('echo 1 > usb/online; ng_observe Charging; ng_pause_reason=limit; ng_observe Discharging; ng_observe Discharging; ng_observe Idle; ng_observe Charging; echo 0 > usb/online; ng_observe Discharging')
        self.assertEqual(['connected:Charger connected','paused:Charging paused at configured limit: 60%','idle:Battery idle detected','resumed:Charging resumed','disconnected:Charger disconnected'],out)

    def test_no_idle_claim_from_battery_percentage(self):
        self.assertEqual(['connected:Charger connected'],self.events('echo 90 > battery/cap; echo 1 > usb/online; ng_observe Charging; ng_observe Charging'))

    def test_unknown_online_data_does_not_claim_disconnect(self):
        self.assertEqual(['connected:Charger connected'],self.events('echo 1 > usb/online; ng_observe Charging; rm usb/online; echo 1 > bms/online; ng_observe Discharging'))

    def test_battery_online_enum_is_not_a_connected_charger(self):
        self.assertEqual([], self.events('echo 1 > battery/online; echo 0 > usb/online; ng_observe Discharging'))

    def test_thermal_and_low_battery_notifications_are_deduplicated(self):
        out=self.events('echo 1 > usb/online; ng_observe Charging; echo 360 > battery/temp; ng_observe Charging; ng_observe Charging; echo 510 > battery/temp; ng_observe Charging; ng_observe Charging; echo 0 > usb/online; echo 19 > battery/cap; ng_observe Discharging; echo 18 > battery/cap; ng_observe Discharging')
        self.assertEqual(['connected:Charger connected','warm:Battery reached configured cooldown temperature','hot:Battery reached configured temperature limit','disconnected:Charger disconnected','low:Battery low: 19%'],out)

    def test_disabled_notifications_still_record_diagnostics(self):
        with tempfile.TemporaryDirectory() as td:
            pathlib.Path(td,'logs').mkdir()
            self.run_shell(f'dataDir={td}; ngNotifications=false; . {ROOT}/install/ng-events.sh; ng_emit low "Battery low: 19%" "Bateria fraca: 19%"')
            self.assertIn('low Battery low: 19%',pathlib.Path(td,'logs/ng-events.log').read_text())

    def test_non_percent_limits_and_state_are_observable(self):
        self.assertIn('paused:Charging paused at configured limit: 3900mV',self.events('capacity=(2 101 3800 3900 false false); echo 1 > usb/online; ng_observe Charging; ng_pause_reason=limit; ng_observe Discharging'))

    def test_critical_original_control_paths_remain(self):
        self.assertIn('below_abs_lims || break',function('ctrl_charging'))
        self.assertIn('! not_charging Discharging || shutdown',function('ctrl_charging'))
        self.assertIn('force_off',function('ctrl_charging'))

    def test_global_ng_preferences_survive_profile_writes(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);(p/'.config-ver').write_text('202310160');(p/'.config-help').write_text('')
            sed_shim = "sed() { if [ \"$1\" = -i ] && [ \"$(uname)\" = Darwin ]; then shift; command sed -i '' \"$@\"; else command sed \"$@\"; fi; }; \n"
            script=sed_shim+f'TMPDIR={td}; config={td}/config; touch "$config"; . {ROOT}/install/default-config.txt; ngNotifications=false; ngNotificationLanguage=pt-PT; pause_capacity=60; resume_capacity=50; . {ROOT}/install/write-config.sh; grep -E "^(capacity|ngNotifications|ngNotificationLanguage)=" "$config"'
            self.assertEqual(['ngNotifications=false','ngNotificationLanguage=pt-PT','capacity=(5 50 50 60 false false)'],self.run_shell(script))
