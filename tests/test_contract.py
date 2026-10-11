"""NG API 1 behaviour and shared frontend fixtures (host or opt-in Android)."""
import json
from pathlib import Path
import shlex
import unittest
from contract_cases import ROOT, collect, config_case, function, run


class ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.actual = collect()

    def test_shared_outputs_are_reproduced_by_production_shell(self):
        expected = json.loads((ROOT / 'tests/fixtures/frontend-contract.json').read_text())
        self.assertEqual(expected, self.actual)

    def test_version_dispatch_matches_release_identity(self):
        self.assertEqual({"code": 0, "output": "v1.0.7-ng (202610117)"}, self.actual["version"]["current"])

    def test_default_schema_and_output_are_preserved(self):
        output = self.actual['config']['default']['output']
        self.assertIn('pause_capacity=75', output)
        self.assertIn('resume_capacity=70', output)
        self.assertIn('resume_temp=45', output)
        self.assertIn('capacity_mask=false', output)
        self.assertIn('capacity_sync=false', output)
        self.assertIn('discharge_polarity=', output)

    def test_profile_write_readback_preserves_preferences_and_manual_switch(self):
        raw = self.actual['config']['profile']['raw']
        output = self.actual['config']['profile']['output']
        self.assertIn('capacity=(2 101 50 60 false false)', raw)
        self.assertIn('temperature=(35 50 40r 55)', raw)
        self.assertIn('ngNotifications=false', raw)
        self.assertIn('ngNotificationLanguage=pt-PT', raw)
        self.assertIn('charging_switch=battery/charging_enabled 1 0 --', output)
        self.assertIn('apply_on_boot=battery/current_max::500::1800', output)
        self.assertIn('max_charging_voltage=4100', output)

    def test_raw_voltage_capacity_does_not_become_percent_or_lose_sixth_element(self):
        self.assertIn('capacity=(2 101 3800 3900 true false)',
                      self.actual['config']['voltage-profile']['raw'])

    def test_cooldown_stats_and_capacity_flags_survive_writes(self):
        result = self.actual['config']['cooldown']
        self.assertIn('capacity=(2 55 50 60 true true)', result['raw'])
        self.assertIn('cooldown_charge=30', result['output'])
        self.assertIn('cooldown_pause=5', result['output'])
        self.assertIn('reset_batt_stats_on_unplug=true', result['output'])
        self.assertIn('capacity_mask=true', result['output'])
        self.assertIn('capacity_sync=true', result['output'])

    def test_unreadable_external_sensor_does_not_authorize_calibration(self):
        result = run('mkdir usb usb/online; echo USB > usb/type\n' +
            function('batt-interface.sh', 'online') + '\nif online; then echo HOLD; else echo UNPLUGGED; fi')
        self.assertEqual({'code': 0, 'output': 'HOLD'}, result)

    def test_profile_rewrite_preserves_calibration_and_global_language(self):
        result = config_case('''
dischargePolarity=-; idleThreshold=25; ngNotifications=false; ngNotificationLanguage=pt-BR
capacity=(2 101 50 60 false false)
''', write=True)
        self.assertIn('dischargePolarity=-', result['raw'])
        self.assertIn('idleThreshold=25', result['raw'])
        self.assertIn('ngNotificationLanguage=pt-BR', result['raw'])
        self.assertIn('ng_notifications=false', result['output'])

    def test_normalized_information_matches_for_micro_and_milli_sensors(self):
        micro = self.actual['info']['micro-charging']
        self.assertEqual(micro, self.actual['info']['milli-charging'])
        self.assertIn('CURRENT_NOW=1.80', micro['output'])
        self.assertIn('VOLTAGE_NOW=4.20', micro['output'])
        self.assertIn('POWER_NOW=7.56', micro['output'])
        self.assertIn('CAPACITY=60', micro['output'])
        self.assertIn('TEMP=325', micro['output'])

    def test_current_sign_zero_and_idle_are_preserved(self):
        self.assertIn('CURRENT_NOW=-0.75', self.actual['info']['discharging']['output'])
        self.assertIn('STATUS=Discharging', self.actual['info']['discharging']['output'])
        self.assertIn('STATUS=Not charging', self.actual['info']['idle']['output'])
        self.assertIn('CURRENT_NOW=0.00', self.actual['info']['zero']['output'])

    def test_missing_or_invalid_data_never_fabricates_a_zero_measurement(self):
        for name in ['missing-current', 'malformed-current']:
            with self.subTest(name=name):
                self.assertNotIn('CURRENT_NOW=', self.actual['info'][name]['output'])
                self.assertNotIn('POWER_NOW=', self.actual['info'][name]['output'])
        for name in ['missing-voltage', 'malformed-voltage']:
            with self.subTest(name=name):
                self.assertNotIn('VOLTAGE_NOW=', self.actual['info'][name]['output'])
                self.assertNotIn('POWER_NOW=', self.actual['info'][name]['output'])

    def test_verbose_output_has_raw_then_normalized_values(self):
        output = self.actual['info']['verbose']['output']
        self.assertLess(output.index('CURRENT_NOW=1800000'), output.index('CURRENT_NOW=1.80'))

    def test_daemon_and_switch_exit_codes_remain_distinct(self):
        self.assertEqual(0, self.actual['daemon']['running']['code'])
        self.assertEqual(9, self.actual['daemon']['stopped']['code'])
        self.assertEqual(8, self.actual['daemon']['already-running']['code'])
        self.assertEqual(0, self.actual['switch']['working']['code'])
        self.assertEqual(15, self.actual['switch']['idle']['code'])
        self.assertEqual(10, self.actual['switch']['failed']['code'])
        self.assertIn('- battIdleMode=true', self.actual['switch']['idle']['output'])

    def test_metadata_advertises_only_current_contract(self):
        fields = dict(line.split('=', 1) for line in self.actual['module'].splitlines())
        self.assertEqual('1', fields['ngApiVersion'])
        self.assertEqual('202310160', fields['ngConfigSchema'])
        self.assertEqual(7, len(fields['ngCapabilities'].split(',')))
        self.assertNotIn('idle-apps', fields['ngCapabilities'])

    def test_shell_status_handles_polarity_and_current_units(self):
        for factor, positive, negative, idle in [('1000', '750', '-750', '10'),
                                                ('1000000', '750000', '-750000', '10000')]:
            for current, expected in [(positive, 'Charging'), (negative, 'Discharging'), (idle, 'Idle')]:
                with self.subTest(factor=factor, current=current):
                    script = f'''mkdir battery; echo Charging > battery/status
 echo {current} > battery/current_now; echo null > previous
battStatus=battery/status; currFile=battery/current_now; curThen=$PWD/previous
idleThreshold=40; ampFactor={factor}; ampFactor_={factor}; dischargePolarity=-
battStatusWorkaround=true; battStatusOverride=; chargingSwitch=(); loopDelay=(1 1)
tt() {{ case "$1" in */current_now) return 0;; *) return 1;; esac; }}
'''
                    script += function('batt-interface.sh', 'online') + '\n'
                    for name in ['read_status', 'idle_discharging', 'status', 'not_charging']:
                        script += function('batt-interface.sh', name) + '\n'
                    result = run(script + 'not_charging || :\necho "$_status"')
                    self.assertEqual({'code': 0, 'output': expected}, result)

    def test_reloaded_raw_profile_keeps_preferences_calibration_and_array_shape(self):
        profile = self.actual['config']['profile']['raw']
        script = "printf %s " + shlex.quote(profile) + ' > "$config"\n'
        script += (ROOT / 'install/default-config.txt').read_text() + '\n. "$config"\nset -- ns\n'
        script += (ROOT / 'install/print-config.sh').read_text()
        self.assertEqual({'code': 0, 'output': self.actual['config']['profile']['output']}, run(script))

    def test_external_supply_matrix_without_live_sysfs(self):
        cases = [
            ({'battery': ('1', 'Battery'), 'usb': ('0', 'USB')}, False),
            ({'vendor-charger': ('1', 'USB_PD')}, True),
            ({'dc': ('1', 'Mains')}, True),
            ({'wireless': ('1', 'Wireless')}, True),
            ({'bms': ('1', 'BMS'), 'otg': ('1', ''), 'ac': ('0', 'Mains')}, False),
            ({'main_battery': ('1', 'Battery'), 'usb': ('0', 'USB')}, False),
            ({'usb': ('2', 'USB')}, True),  # unknown conservatively holds calibration
            ({'usb': ('', 'USB')}, True),
            ({}, True),
        ]
        for supplies, held_or_connected in cases:
            with self.subTest(supplies=supplies):
                script = ''
                for name, (value, kind) in supplies.items():
                    script += f'mkdir {name}; echo "{value}" > {name}/online; echo "{kind}" > {name}/type\n'
                script += function('batt-interface.sh', 'online') + '\n'
                result = run(script + 'if online; then echo HOLD; else echo UNPLUGGED; fi')
                self.assertEqual({'code': 0, 'output': 'HOLD' if held_or_connected else 'UNPLUGGED'}, result)
