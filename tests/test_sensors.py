"""Physical sensor semantics with synthetic files on host and Android."""
import shlex
import unittest
from contract_cases import ROOT, run, source
from test_engine import function as daemon_function


class SensorTests(unittest.TestCase):
    def check(self, commands, expected):
        script = source('sensor-discovery.sh') + '\n' + commands
        result = run(script)
        self.assertEqual({'code': 0, 'output': expected}, result)

    def test_split_nexus_interface_without_uevent_and_battery_current(self):
        self.check('''mkdir ds2784-fuelgauge smb347-battery
echo 65 > ds2784-fuelgauge/capacity
echo Discharging > smb347-battery/status
echo 275 > smb347-battery/temp
echo -350000 > smb347-battery/current_now
echo 4100000 > ds2784-fuelgauge/voltage_now
ng_discover_battery
echo "$battCapacity:$battStatus:$temp:$currentIsBattery:$ampFactor_:$voltFactor"
''', 'ds2784-fuelgauge/capacity:smb347-battery/status:smb347-battery/temp:true:1000000:1000000')

    def test_current_prefers_battery_over_input_and_honours_explicit_units(self):
        self.check('''mkdir battery rt9471-charger
echo 50 > battery/capacity; echo Charging > battery/status
echo 300 > battery/temp; echo 1200 > battery/current_now
echo uA > battery/current_now_unit
echo 1800000 > rt9471-charger/current_now
ng_discover_battery
echo "$currFile:$ampFactor_:$currentIsBattery"
rm battery/current_now
ng_discover_battery
echo "$currFile:$ampFactor_:$currentIsBattery"
''', 'battery/current_now:1000000:true\nrt9471-charger/current_now:1000000:false')

    def test_missing_or_invalid_sensors_do_not_fabricate_telemetry(self):
        self.check('''mkdir battery
echo 50 > battery/capacity; echo Charging > battery/status
echo null > battery/temp; echo '12oops' > battery/current_now
echo 0 > battery/voltage_now
ng_discover_battery
echo "$hasCurrentSensor:$hasTemperatureSensor:$hasVoltageSensor"
test ! -s "$temp"; test ! -s "$currFile"; test ! -s "$voltNow"
capacity=(2 101 50 60 false false)
if ng_telemetry_valid; then exit 99; fi
echo PROTECTED
''', 'false:false:false\nPROTECTED')

    def test_invalid_capacity_or_status_is_not_an_interface(self):
        self.check('''mkdir battery
echo 101 > battery/capacity; echo Charging > battery/status
if ng_discover_battery; then exit 99; fi
echo 50 > battery/capacity; echo broken > battery/status
if ng_discover_battery; then exit 99; fi
echo REJECTED
''', 'REJECTED')

    def test_zero_and_configured_units_are_preserved(self):
        self.check('''mkdir battery
echo 50 > battery/capacity; echo Discharging > battery/status
echo 300 > battery/temp; echo 0 > battery/current_now
ampFactor=1000000
ng_discover_battery
echo "$hasCurrentSensor:$ampFactor_"
''', 'true:1000000')

    def test_voltage_threshold_requires_a_physical_voltage_sensor(self):
        self.check('''mkdir battery
echo 50 > battery/capacity; echo Charging > battery/status
echo 300 > battery/temp
ng_discover_battery
capacity=(2 101 50 60 false false)
ng_telemetry_valid; echo CAPACITY_OK
capacity=(2 101 3800 3900 false false)
if ng_telemetry_valid; then exit 99; fi
echo VOLTAGE_UNAVAILABLE
''', 'CAPACITY_OK\nVOLTAGE_UNAVAILABLE')

    def test_info_reads_selected_physical_nodes_without_uevent(self):
        self.check('''mkdir battery
echo 60 > battery/capacity; echo Charging > battery/status
echo 325 > battery/temp; echo 750000 > battery/current_now
echo 4200000 > battery/voltage_now
ng_discover_battery
verbose=false
not_charging() { _status=Charging; return 1; }
tt() { return 1; }; print_A() { :; }; print_V() { :; }; print_W() { :; }
''' + source('batt-info.sh') + '''
batt_info | grep -E '^(STATUS|CAPACITY|TEMP|CURRENT_NOW|VOLTAGE_NOW|POWER_NOW)='
''', 'STATUS=Charging\nCAPACITY=60\nTEMP=325\nCURRENT_NOW=0.75\nVOLTAGE_NOW=4.20\nPOWER_NOW=3.15')

    def test_input_current_is_never_battery_current_or_power(self):
        self.check('''mkdir battery rt9471-charger
echo 60 > battery/capacity; echo Charging > battery/status
echo 325 > battery/temp; echo 1800000 > rt9471-charger/current_now
echo 4200000 > battery/voltage_now
ng_discover_battery
verbose=false
not_charging() { _status=Charging; return 1; }
tt() { return 1; }; print_A() { :; }; print_V() { :; }; print_W() { :; }
''' + source('batt-info.sh') + '''
batt_info > info
if grep -Eq '^(CURRENT_NOW|POWER_NOW)=' info; then exit 99; fi
grep -E '^(INPUT_CURRENT_NOW|CURRENT_ROLE)=' info
''', 'INPUT_CURRENT_NOW=1.80\nCURRENT_ROLE=input')

    def test_oem_rules_are_exact_and_preserve_manual_selection(self):
        # Exercise OEM policy without migration/special live filesystem writes.
        oem = source('oem-custom.sh')
        begin = oem.index('ng_oem_defaults() {')
        end = oem.index('\n}\nng_oem_defaults', begin) + 2
        helper = oem[begin:end]
        self.check('''touch ch-switches
echo 'battery/charging_enabled 1 0' > ch-switches
configSwitch='battery/manual 1 0 --'
_get_prop() { echo "$configSwitch"; }
_grep() { grep -Eq "$1" "$2"; }
ng_save_switch() { echo "$1"; }
board=msm8953
getprop() { echo "$board"; }
''' + helper + '''
ng_oem_defaults
configSwitch=; ng_oem_defaults
board=other-msm8953; ng_oem_defaults
board=msm8937; ng_oem_defaults
test -f .current-status-disabled
board=samsung; ng_oem_defaults
test ! -e .current-status-disabled
echo MANUAL_PRESERVED
''', 'battery/charging_enabled 1 0 --\nMANUAL_PRESERVED')

    def test_catalogue_has_no_duplicates_and_experimental_controls_are_explicit(self):
        self.check(source('ctrl-files.sh') + '''
ls_ch_switches | sed '/^#/d; /^$/d' > switches
test "$(sort switches | uniq -d | wc -l | tr -d ' ')" = 0
grep -Fx '/sys/class/asuslib/charging_suspend_en 0 1' switches
grep -Fx '/sys/devices/platform/charger/bypass_charger 0 1' switches
if grep -Eq 'wireless_boost_en|cool_down|force_fast_charge' switches; then exit 99; fi
''', '/sys/class/asuslib/charging_suspend_en 0 1\n/sys/devices/platform/charger/bypass_charger 0 1')

    def test_lost_temperature_pauses_without_shutdown_or_control_probe(self):
        self.check('''mkdir battery
echo 50 > battery/capacity; echo Charging > battery/status
echo 300 > battery/temp
ng_discover_battery
rm battery/temp
capacity=(2 101 50 60 false false); loopDelay=(1 1)
execDir=$TMPDIR; ng_engine_state() { :; }; flip_sw() { echo "CONTROL:$1"; }
notif() { echo DIAGNOSTIC; }
sleep() { exit 0; }
is_charging() { echo UNEXPECTED_PROBE; exit 99; }
shutdown() { echo UNEXPECTED_SHUTDOWN; exit 99; }
''' + daemon_function('ctrl_charging') + '\nctrl_charging', 'CONTROL:off\nDIAGNOSTIC')

    def test_status_protocol_identifies_input_current_and_missing_values(self):
        self.check('''mkdir battery rt9471-charger
echo 60 > battery/capacity; echo Discharging > battery/status
echo 1800000 > rt9471-charger/current_now
ng_discover_battery
ng_print_sensor_status | grep -E '^(sensor|currentRole|current|factor|temperature|voltage)='
''', 'current=1800000\nfactor=1000000\nsensor=false\ncurrentRole=input')
