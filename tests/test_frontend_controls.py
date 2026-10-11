"""Execute the real frontend dispatch against a relocated synthetic module."""
import os
import shlex
import unittest
import test_limits
from contract_cases import ROOT, function, source

class FrontendControlsTests(unittest.TestCase):
    run_shell = test_limits.LimitTests.run_shell

    def frontend(self):
        script = ''
        for name in ['limit-control.sh', 'control-write.sh', 'control-discovery.sh',
                     'ng-power-limits.sh', 'external-power.sh', 'sensor-discovery.sh', 'set-ch-curr.sh',
                     'set-ch-volt.sh', 'batt-interface.sh', 'default-config.txt']:
            script += 'printf %s ' + shlex.quote(source(name)) + f' > {name}\n'
        text = source('acca.sh')
        interpreter = '/system/bin/sh' if os.environ.get('ACC_TEST_ADB_SERIAL') else 'bash'
        for before, after in [('execDir=/data/adb/vr25/acc', 'execDir=$PWD'),
                              ('config=/data/adb/vr25/acc-data/config.txt', 'config=$PWD/config'),
                              ('dataDir=/data/adb/vr25/acc-data', 'dataDir=$PWD'),
                              ('TMPDIR=/dev/.vr25/acc', 'TMPDIR=$PWD'),
                              ('cd /sys/class/power_supply/', 'cd "$TMPDIR"')]:
            text = text.replace(before, after)
        if interpreter == 'bash': text = text.replace('/system/bin/sh', 'bash')
        script += 'printf %s ' + shlex.quote(text) + ' > acca-fixture.sh\n'
        script += f'frontend() {{ async=true {interpreter} ./acca-fixture.sh "$@"; }}\n'
        script += '''
: > setup-busybox.sh; : > .config-help
echo 202310160 > .config-ver
cp default-config.txt "$config"
echo 'battStatusWorkaround=false' >> "$config"
echo 'batt=battery
battCapacity=battery/capacity
battStatus=battery/status
currFile=battery/current_now
curThen=./.curr
temp=battery/temp
voltNow=battery/voltage_now
ampFactor_=1000000' > .batt-interface.sh
echo Charging > battery/status; echo 60 > battery/capacity
echo 300 > battery/temp; echo 1800000 > battery/current_now
echo 4200000 > battery/voltage_now
mkdir usb; echo 1 > usb/online
'''
        return script

    def test_saved_applied_and_reset_use_production_frontend_dispatch(self):
        self.assertEqual(['current.requested=500', 'current.state=applied', '500',
                          'current.requested=default', 'current.state=off', '1800'], self.run_shell(self.frontend() + '''
echo 1800 > battery/current_max
frontend --set --current 500
frontend --power-status | grep -E 'current.(requested|state)'
cat battery/current_max
frontend --set --current -
frontend --power-status | grep -E 'current.(requested|state)'
cat battery/current_max
'''))

    def test_frontend_offline_request_is_saved_and_not_misreported_as_applied(self):
        self.assertEqual(['current.requested=500', 'current.state=pending', '1800'], self.run_shell(self.frontend() + '''
echo Discharging > battery/status; echo 0 > usb/online
echo 1800 > battery/current_max
frontend --set --current 500
frontend --power-status | grep -E 'current.(requested|state)'
cat battery/current_max
'''))

    def test_failed_frontend_write_still_saves_request_and_exposes_failure(self):
        self.assertEqual(['current.requested=500', 'current.state=failed', '1800'], self.run_shell(self.frontend() + '''
echo 1800 > battery/current_max
# Replace only the hardware primitive; preserve the real frontend writer.
echo 'write_control() { return 1; }' >> limit-control.sh
frontend --set --current 500
frontend --power-status | grep -E 'current.(requested|state)'
cat battery/current_max
'''))

    def test_logged_discovery_obeys_final_blacklist_and_live_validation(self):
        setup = function('acc.sh', 'parse_switches') + '''
: > ch-switches; : > log-input
for name in charger_enable authentic fcc_step moisture_detect ship_mode reverse_charging store_mode; do
 echo 1 > "battery/$name"
 printf '/sys/class/power_supply/battery/%s\\n  1\\n' "$name" >> log-input
done
printf '/sys/class/power_supply/battery/missing_enable\\n  1\\n' >> log-input
parse_switches ch-switches log-input
'''
        self.assertEqual(['battery/charger_enable 1 0'], self.run_shell(setup))

    def test_discovery_switch_save_preserves_latest_settings_and_manual_choice(self):
        self.assertEqual(['capacity=(5 50 70 80 false false)',
                          'maxChargingCurrent=(500)', 'MANUAL_PRESERVED'], self.run_shell(self.frontend() + '''
. "$config"; capacity=(5 50 70 80 false false); maxChargingCurrent=(500)
. "$execDir/write-config.sh"
# The daemon retains an older in-memory profile.
capacity=(5 50 50 60 false false); maxChargingCurrent=(1200)
ng_save_switch 'battery/charging_enabled 1 0'
grep '^capacity=' "$config"; grep '^maxChargingCurrent=' "$config"
. "$config"; s="battery/charging_enabled 1 0 --"
. "$execDir/write-config.sh"
cp "$config" expected-config
if ng_save_switch 'battery/other_switch 1 0'; then exit 99; fi
cmp expected-config "$config"; echo MANUAL_PRESERVED
'''))
