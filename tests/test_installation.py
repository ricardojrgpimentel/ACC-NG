"""Execute installers against an isolated filesystem on host or Android.

All Android paths in production scripts are redirected below the fixture root.
Platform/daemon tools are stubbed; no installed module or charging node is used.
"""
import os
import re
import shlex
import unittest

from contract_cases import ROOT, run


class InstallationTests(unittest.TestCase):
    def scenario(self, staging='acc-upgrade', fail_copy=False, clean=False, uninstall=False,
                 tarball=False):
        shell = '/system/bin/sh' if os.environ.get('ACC_TEST_ADB_SERIAL') else '/bin/bash'

        def write(path, text):
            return 'mkdir -p "$(dirname ' + shlex.quote(path) + ')"\nprintf %s ' + shlex.quote(text) + ' > ' + shlex.quote(path) + '\n'

        def redirected(text):
            text = re.sub(r'(?<![\w}])/(data|dev|proc|sbin|system)/',
                          r'${fixture_root}/\1/', text)
            # Scripts invoked directly (service/tool stubs) need a real interpreter.
            return '#!' + shell + '\n' + text.split('\n', 1)[1]

        script = '''fixture_root=$PWD; export fixture_root
mkdir -p data/adb/modules/acc data/adb/vr25/acc-data/logs data/adb/service.d \
  data/local/tmp/acc-keep data/local/tmp/acc_keep dev/.vr25/busybox system/bin
ln -s "$fixture_root/data/adb/modules/acc" data/adb/vr25/acc
echo old > data/adb/modules/acc/old-runtime
echo 'capacity=(2 101 50 60 false false)' > data/adb/vr25/acc-data/config.txt
echo 'ngNotifications=false' >> data/adb/vr25/acc-data/config.txt
cp data/adb/vr25/acc-data/config.txt expected-config
echo keep > data/local/tmp/acc-keep/sentinel
echo keep > data/local/tmp/acc_keep/sentinel
real_cp=$(command -v cp); export real_cp
'''
        service = '#!' + shell + '\necho init >> "$fixture_root/init.log"\n'
        script += write('data/adb/modules/acc/service.sh', service)
        script += 'chmod 755 data/adb/modules/acc/service.sh\n'
        script += 'ln -s "$(command -v ls)" dev/.vr25/busybox/ls\n'
        tools = {
            'sh': 'exec ' + shlex.quote(shell) + ' "$@"',
            'id': 'echo 0', 'chown': ':', 'chcon': ':', 'restorecon': ':',
            'pgrep': 'exit 1', 'pkill': 'exit 77', 'sleep': ':', 'which': 'exit 1',
            'timeout': 'shift; "$@"', 'flock': 'shift; "$@"',
            'cp': '''if [ "$1" = -R ] && [ -f "$fixture_root/fail-copy-once" ]; then
  rm "$fixture_root/fail-copy-once"
  exit 42
fi
exec "$real_cp" "$@"''',
        }
        for name, body in tools.items():
            script += write('system/bin/' + name, '#!' + shell + '\n' + body + '\n')
        script += 'chmod 755 system/bin/*\nPATH="$fixture_root/system/bin:$PATH"; export PATH\n'
        source_rel = 'data/local/tmp/' + staging + ('/acc-ng-fixture' if tarball else '')
        for name in ('install.sh', 'install/uninstall.sh'):
            script += write(source_rel + '/' + name, redirected((ROOT / name).read_text()))
        for name, content in {
            'install/service.sh': service, 'install/new-runtime': 'new\n',
            'install/acc.sh': '#!' + shell + '\nexit 0\n',
            'install/acca.sh': '#!' + shell + '\nexit 0\n',
            'module.prop': (ROOT / 'module.prop').read_text(),
            'README.md': 'fixture\n', 'changelog.md': 'fixture\n',
            'bin/acc_flashable_uninstaller.zip': 'fixture\n',
        }.items():
            script += write(source_rel + '/' + name, content)
        if tarball:
            script += write('data/local/tmp/' + staging + '/install-tarball.sh',
                            redirected((ROOT / 'install-tarball.sh').read_text()))
            script += 'tar -czf data/local/tmp/' + staging + '/acc_fixture.tgz -C data/local/tmp/' + staging + ' acc-ng-fixture\n'
            script += 'rm -rf ' + shlex.quote(source_rel) + '\n'
        if clean:
            script += 'rm -rf data/adb/modules/acc data/adb/vr25/acc data/adb/vr25/acc-data/config.txt\n'
        if fail_copy:
            script += 'touch fail-copy-once\n'
        source = '$fixture_root/' + source_rel
        command = '"' + source + '/install/uninstall.sh"' if uninstall else '"' + source + '/install.sh"'
        if tarball:
            command = '"$fixture_root/data/local/tmp/' + staging + '/install-tarball.sh"'
        script += '''trap 'e=$?; if [ "$e" != 0 ]; then cat output.log data/adb/vr25/acc-data/logs/install.log 2>/dev/null || :; fi' EXIT
'''
        script += 'set +e\nKSU=false ' + shlex.quote(shell) + ' ' + command + ' > output.log 2>&1\nstatus=$?\nset -e\n'
        # Assert results inside the same fixture directory before it is removed.
        script += '''test -f data/local/tmp/acc-keep/sentinel
test -f data/local/tmp/acc_keep/sentinel
'''
        if tarball:
            script += 'test ! -e "' + source + '"\n'
            script += 'test -f data/local/tmp/' + staging + '/install-tarball.sh\n'
        else:
            script += 'test -f "' + source + '/install/uninstall.sh"\n'
        if uninstall:
            script += '''test "$status" = 0
test ! -e data/adb/modules/acc
test ! -e data/adb/vr25/acc-data
'''
        else:
            script += 'test "$status" = ' + ('42' if fail_copy else '0') + '\n'
            script += 'test "$(wc -l < init.log | tr -d " ")" = 1\n'
            if not clean:
                script += '''cmp expected-config data/adb/vr25/acc-data/config.txt
set -- data/adb/vr25/acc-data/backup/install-*
test "$#" = 1
cmp expected-config "$1/config.txt"
test -f "$1/module/old-runtime"
'''
            if fail_copy:
                script += '''test -f data/adb/modules/acc/old-runtime
test ! -e data/adb/modules/acc/new-runtime
'''
            else:
                script += '''test ! -e data/adb/modules/acc/old-runtime
test -f data/adb/modules/acc/new-runtime
'''
        result = run(script + 'echo verified\n')
        self.assertEqual({'code': 0, 'output': 'verified'}, result,
                         result['output'][-3000:])

    def test_upgrade_preserves_source_and_unrelated_staging(self):
        for staging in ('acc-upgrade', 'acc_upgrade', 'acc-parent/nested', 'ng-candidate'):
            with self.subTest(staging=staging):
                self.scenario(staging=staging)

    def test_failed_upgrade_restores_module_config_and_original_failure(self):
        self.scenario(staging='acc-recovery', fail_copy=True)

    def test_clean_install_from_matching_staging(self):
        self.scenario(staging='acc-clean', clean=True)

    def test_full_uninstall_removes_module_data_but_preserves_staging(self):
        self.scenario(staging='acc-uninstall', uninstall=True)

    def test_tarball_upgrade_cleans_only_its_extracted_source(self):
        self.scenario(staging='acc-tarball', tarball=True)

    def test_tarball_failed_upgrade_recovers_before_source_cleanup(self):
        self.scenario(staging='acc-tarball-recovery', tarball=True, fail_copy=True)
