import shlex
import unittest
from contract_cases import source, function, run

class ExternalPowerTests(unittest.TestCase):
    def test_controller_and_events_share_tristate_supply_semantics(self):
        cases = [({'battery': ('1', 'Battery'), 'usb': ('0', 'USB')}, 1),
                 ({'main_battery': ('1', 'Battery'), 'usb': ('0', 'USB')}, 1),
                 ({'reverse': ('1', 'USB_OTG'), 'usb': ('0', 'USB')}, 1),
                 ({'usb': ('0', 'USB'), 'dc': ('invalid', 'Mains')}, 2),
                 ({'usb': ('1', 'USB'), 'dc': ('invalid', 'Mains')}, 0),
                 ({'vendor-charger': ('1', 'USB_PD')}, 0),
                 ({'wireless': ('1', 'Wireless')}, 0),
                 ({'usb': ('2', 'USB')}, 2), ({}, 2)]
        for supplies, expected in cases:
            with self.subTest(supplies=supplies):
                script = function('batt-interface.sh', 'online') + '\n' + function('ng-events.sh', 'ng_online') + '\n'
                for name, (value, kind) in supplies.items():
                    script += f'mkdir {name}; printf %s {shlex.quote(value)} > {name}/online; echo {kind} > {name}/type\n'
                script += 'if ng_online; then echo EVENT:0; else echo EVENT:$?; fi\n'
                script += 'if online; then echo HOLD; else echo UNPLUGGED; fi\n'
                result = run(script)
                self.assertEqual({'code': 0, 'output': f'EVENT:{expected}\n' + ('UNPLUGGED' if expected == 1 else 'HOLD')}, result)

    def test_unreadable_source_beside_disconnected_is_unknown(self):
        result = run(source('external-power.sh') + '\nmkdir -p usb dc/online; echo 0 > usb/online\n'
                     'if ng_power_state; then echo CONNECTED; else echo $?; fi')
        self.assertEqual({'code': 0, 'output': '2'}, result)
