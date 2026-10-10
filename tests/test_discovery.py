"""Behavioural I3 fixtures, including real Android locks via the shared runner."""
import test_limits
import unittest

class DiscoveryTests(unittest.TestCase):
    run_shell = test_limits.LimitTests.run_shell
    # Inherit the fixture runner, not a second copy of the I1 suite.
    def test_discovery_uses_original_snapshot_after_cache_loss_and_restart(self):
        self.assertEqual(['500', 'battery/current_max::v::1800', '1800'], self.run_shell('''
echo 1800 > battery/current_max
set_ch_curr 500
cat battery/current_max
rm ch-curr-ctrl-files .ch-curr-read
ng_discover_controls current
cat ch-curr-ctrl-files
# A restart source/config may still carry an old cached default.
maxChargingCurrent=(500 battery/current_max::500::500)
set_ch_curr -
cat battery/current_max
'''))

    def test_units_strict_validation_blacklist_and_permissions(self):
        self.assertEqual(['battery/constant_charge_current_max::v000::1800000',
                          'battery/voltage_max::v000::4200000', '500000:4100000'], self.run_shell('''
echo 1800000 > battery/constant_charge_current_max
echo 4200000 > battery/voltage_max
echo 1500junk > battery/current_max
mkdir parallel bq25890
echo 2000 > parallel/current_max; echo 1800 > bq25890/current_max
echo 1 > battery/store_mode
chmod() { echo UNEXPECTED_CHMOD; return 99; }
ng_discover_controls current; ng_discover_controls voltage
cat ch-curr-ctrl-files; cat ch-volt-ctrl-files
set_ch_curr 500; set_ch_volt 4100
echo "$(cat battery/constant_charge_current_max):$(cat battery/voltage_max)"
test "$(cat battery/current_max)" = 1500junk
'''))

    def test_empty_negative_multiline_and_overflow_candidates_never_apply(self):
        self.assertEqual(['current.supported=false', 'current.state=unsupported'], self.run_shell('''
printf '' > battery/current_max
echo -1800 > battery/constant_charge_current_max
echo '1800 2000' > battery/input_current_max
echo 999999999999999 > battery/ac_charge
if set_ch_curr 500; then exit 99; fi
ng_print_limit current 500 | grep -E 'supported|state'
test ! -e .mcc-custom
'''))

    def test_disconnected_discovery_is_bounded_and_request_is_pending(self):
        self.assertEqual(['current.supported=unknown', 'current.state=pending', '1800'], self.run_shell('''
echo 1800 > battery/current_max
not_charging() { return 0; }
sleep() { echo UNEXPECTED_WAIT; exit 99; }
set_ch_curr 500
ng_print_limit current 500 | grep -E 'supported|state'
cat battery/current_max
test ! -e .ch-curr-read; test ! -e .mcc-custom
'''))

    def test_pending_request_applies_later_without_rewriting_config(self):
        self.assertEqual(['500', 'current.state=applied', 'maxChargingCurrent=(500)'], self.run_shell('''
echo 1800 > battery/current_max
echo 'maxChargingCurrent=(500)' > "$config"
not_charging() { return 0; }
set_ch_curr 500
not_charging() { return 1; }
# Simulate daemon holding an old request while frontend already saved another.
maxChargingCurrent=(1200)
ng_apply_config_limits current
cat battery/current_max
ng_print_limit current 500 | grep state
cat "$config"
'''))

    def test_empty_cache_does_not_repeat_discovery_until_invalidated(self):
        self.assertEqual(['EMPTY', '1800'], self.run_shell('''
ng_discover_controls current
# This test deliberately creates a new candidate after the completed probe.
echo 1800 > battery/current_max
ng_discover_controls current
test ! -s ch-curr-ctrl-files; echo EMPTY
rm .ch-curr-read
ng_discover_controls current
set_ch_curr 500; set_ch_curr -
cat battery/current_max
'''))

    def test_readback_requires_application_and_detects_oem_drift(self):
        self.assertEqual(['current.state=pending', 'current.state=applied',
                          'current.state=failed', 'current.state=failed'], self.run_shell('''
echo 1800 > battery/current_max
ng_discover_controls current
# Even a coincidental matching value is not proof of an ACC-NG apply.
echo 500 > battery/current_max
ng_print_limit current 500 | grep state
set_ch_curr 500
ng_print_limit current 500 | grep state
echo 700 > battery/current_max
ng_print_limit current 500 | grep state
rm battery/current_max
ng_print_limit current 500 | grep state
'''))

    def test_refused_application_and_reset_remain_failed(self):
        self.assertEqual(['current.state=failed', 'current.state=failed'], self.run_shell('''
echo 1800 > battery/current_max
write_control() { return 1; }
if set_ch_curr 500; then exit 99; fi
ng_print_limit current 500 | grep state
write_control() { echo "$1" > "$2"; }
set_ch_curr 500
write_control() { return 1; }
if set_ch_curr -; then exit 99; fi
ng_print_limit current default | grep state
'''))

    def test_switch_filter_rejects_missing_empty_refused_and_blacklisted(self):
        self.assertEqual(['battery/charging_enabled 1 0', 'REJECTED', 'REJECTED', 'REJECTED', 'REJECTED'], self.run_shell('''
echo 1 > battery/charging_enabled
ng_filter_switch battery/charging_enabled 1 0
for path in battery/missing battery/empty battery/unreadable battery/store_mode; do
  case "$path" in *empty) touch "$path";; *unreadable) mkdir "$path";; *store_mode) echo 1 > "$path";; esac
  if ng_filter_switch "$path" 1 0; then exit 99; else echo REJECTED; fi
done
'''))


    def test_aliases_are_deduplicated_and_restore_the_actual_original(self):
        self.assertEqual(['1', '1800'], self.run_shell('''
echo 1800 > battery/current_max
ln -s current_max battery/constant_charge_current_max
ng_discover_controls current
wc -l < ch-curr-ctrl-files | tr -d ' '
set_ch_curr 500; set_ch_curr -
cat battery/current_max
'''))

    def test_workaround_change_filters_cached_controls_without_fallback(self):
        self.assertEqual(['usb/current_max::v::1800', 'EMPTY'], self.run_shell('''
mkdir usb; echo 1800 > usb/current_max
ng_discover_controls current
cat ch-curr-ctrl-files
currentWorkaround=true
ng_discover_controls current
test ! -s ch-curr-ctrl-files; echo EMPTY
'''))

    def test_derived_switches_keep_original_defaults_and_do_not_duplicate(self):
        self.assertEqual(['battery/current_max 1800 0', 'battery/current_max 1800 10'], self.run_shell('''
: > ch-switches
echo 1800 > battery/current_max
set_ch_curr 500
ng_add_limit_switches; ng_add_limit_switches
cat ch-switches
'''))

    def test_thermal_reference_requires_a_positive_numeric_range(self):
        self.assertEqual(['battery/system_temp_level 0 battery/num_system_temp_levels',
                          'REJECTED', 'REJECTED', 'REJECTED', 'REJECTED'], self.run_shell('''
echo 0 > battery/system_temp_level; echo 5 > battery/num_system_temp_levels
ng_filter_switch battery/system_temp_level 0 battery/num_system_temp_levels
for value in '' null -1 0; do
 printf '%s' "$value" > battery/num_system_temp_levels
 if ng_filter_switch battery/system_temp_level 0 battery/num_system_temp_levels; then exit 99; else echo REJECTED; fi
done
'''))
