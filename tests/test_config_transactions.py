"""Atomic writes, recovery, partial imports and daily schedule behavior."""
import shlex
import unittest
from contract_cases import run, source, function


class ConfigurationTests(unittest.TestCase):
    def check(self, body, expected):
        script = source('config-transaction.sh') + '\n' + source('default-config.txt') + '\n'
        script += 'printf %s ' + shlex.quote(source('default-config.txt')) + ' > "$config"\n'
        script += 'printf %s ' + shlex.quote(source('write-config.sh')) + ' > writer.sh\n'
        script += 'echo 202310160 > .config-ver; : > .config-help\n' + body
        self.assertEqual({'code': 0, 'output': expected}, run(script))

    def test_full_replacement_preserves_valid_backup_and_refuses_invalid_source(self):
        self.check('''cp "$config" before
echo 'capacity=(' > invalid
ng_replace_config invalid && exit 99 || :
cmp before "$config"
echo 'vendorFeature=reset' > replacement
ng_replace_config replacement
cmp before "${config}.last-good"
grep -Fx vendorFeature=reset "$config"
''', 'vendorFeature=reset')

    def test_script_removal_is_atomic_and_keeps_other_commands(self):
        self.check('''echo ': night=; echo old' >> "$config"
echo ': day=; echo kept' >> "$config"
cp "$config" before
ng_delete_scripts '^: night='
cmp before "${config}.last-good"
grep -Fx ': day=; echo kept' "$config"
! grep -q '^: night=' "$config"
''', ': day=; echo kept')

    def test_failed_removal_commit_preserves_current_profile(self):
        self.check('''echo ': night=; echo old' >> "$config"
cp "$config" before
mv() { for target; do :; done; [ "$target" != "$config" ] || return 42; command mv "$@"; }
ng_delete_scripts '^: night=' && exit 99 || :
cmp before "$config"; echo PRESERVED
''', 'PRESERVED')

    def test_cli_restart_does_not_inherit_configuration_writer_lock(self):
        import os
        shell = '/system/bin/sh' if os.environ.get('ACC_TEST_ADB_SERIAL') else '/bin/bash'
        for arguments in ['r', 'current_workaround=true']:
            with self.subTest(arguments=arguments):
                self.check(function('set-prop.sh', 'set_prop') + '''
execDir=$PWD; defaultConfig=$PWD/default-config.txt
cp "$config" "$defaultConfig"; cp writer.sh write-config.sh
printf %s ''' + shlex.quote(source('config-transaction.sh')) + ''' > config-transaction.sh
src_cfg() { . "$config"; }
daemon_ctrl() { return 0; }
print_config_reset() { :; }
cat > accd <<'SH'
#!''' + shell + '''
flock -n 0 <> "$TMPDIR/.ng-config.lock" || exit 99
echo LOCK_FREE
SH
chmod +x accd
export TMPDIR
set_prop ''' + arguments + '\n', 'LOCK_FREE')

    def test_two_concurrent_writers_keep_profile_and_global_preferences(self):
        self.check('''
( pause_capacity=60; resume_capacity=50; . ./writer.sh ) & one=$!
( ng_notifications=false; ng_notification_language=pt-PT; . ./writer.sh ) & two=$!
wait "$one"; wait "$two"
. "$config"
echo "${capacity[2]}:${capacity[3]}:$ngNotifications:$ngNotificationLanguage"
''', '50:60:false:pt-PT')

    def test_hooks_roundtrip_single_quotes_and_extension_keys(self):
        self.check('''echo 'vendorFeature=enabled' >> "$config"
run_cmd_on_pause="printf '%s' 'hello # world'"
batt_status_override="printf '%s' 'Idle'"
. ./writer.sh
. "$config"
echo "$runCmdOnPause"; echo "$battStatusOverride"; echo "$vendorFeature"
''', "printf '%s' 'hello # world'\nprintf '%s' 'Idle'\nenabled")

    def test_unsafe_switch_tokens_are_serialized_as_data(self):
        self.check('''charging_switch='battery/enable 1 0);touch injected;chargingSwitch=('
. ./writer.sh
. "$config"
test ! -f injected
echo SAFE
''', 'SAFE')

    def test_failed_commit_preserves_last_configuration(self):
        self.check('''cp "$config" before
mv() { for target; do :; done; [ "$target" != "$config" ] || return 42; command mv "$@"; }
pause_capacity=60
set +e; . ./writer.sh; result=$?; set -e
test "$result" -ne 0
cmp before "$config"; test -s "${config}.last-good"
echo PRESERVED
''', 'PRESERVED')

    def test_invalid_candidate_never_replaces_valid_configuration(self):
        self.check('''cp "$config" before
pause_capacity='60; touch injected'
set +e; . ./writer.sh; result=$?; set -e
test "$result" -ne 0
cmp before "$config"; test ! -f injected
echo REJECTED
''', 'REJECTED')

    def test_partial_crlf_import_replaces_named_script_and_retains_extension(self):
        self.check('''echo ': night=; echo old' >> "$config"
echo 'vendorFeature=enabled' >> "$config"
printf 'capacity=(2 101 50 60 false false)\r\n: night=; echo new\r\n' > imported
ng_import_config imported
# Source only assignments, so the test script is not executed.
grep -E '^(capacity|ngNotifications|vendorFeature|: night)' "$config"
test "$(grep -c '^: night=' "$config")" = 1
''', 'ngNotifications=true\ncapacity=(2 101 50 60 false false)\n: night=; echo new\nvendorFeature=enabled')

    def test_named_script_addition_is_case_insensitive_and_preserves_quoting(self):
        self.check('''echo ': Sleep Profile; echo old' >> "$config"
ng_add_script ': "sleep profile"; printf "new # value"'
grep '^:' "$config"
test "$(grep -c '^:' "$config")" = 1
''', ': "sleep profile"; printf "new # value"')

    def test_invalid_import_does_not_change_original(self):
        self.check('''cp "$config" before; echo 'capacity=(' > imported
if ng_import_config imported; then exit 99; fi
cmp before "$config"; echo REJECTED
''', 'REJECTED')

    def test_recovery_preserves_invalid_file_and_restores_last_good(self):
        self.check('''cp "$config" "${config}.last-good"
echo 'capacity=(' > "$config"
ng_load_config
ng_config_check "$config"
grep -Fx 'capacity=(' "${config}.invalid"
echo "$ngNotifications:${capacity[3]}"
''', 'capacity=(\ntrue:75')

    def test_hook_failure_does_not_erase_valid_configuration(self):
        self.check('''echo ': broken; false' >> "$config"
cp "$config" before
ng_load_config
cmp before "$config"
echo "$ngNotifications:${capacity[3]}"
''', 'true:75')

    def test_schedule_once_per_day_including_midnight_and_quoting(self):
        self.check(function('misc-functions.sh', 'at') + '''
fixtureDay=20261011; fixtureTime=23:59
date() { case "$1" in +%H:%M) echo "$fixtureTime";; +%Y%m%d) echo "$fixtureDay";; esac; }
at 23:59 "printf '%s\\n' 'night # one'"
at 23:59 "printf '%s\\n' 'night # one'"
fixtureDay=20261012; fixtureTime=00:00
at 00:00 "echo midnight"
at 00:00 "echo midnight"
fixtureTime=23:59
at 23:59 "printf '%s\\n' 'night # one'"
''', 'night # one\nmidnight\nnight # one')
