"""Boot readiness, archive validation, rollback and diagnostics behavior."""
import io
import os
from pathlib import Path
import shlex
import tarfile
import unittest
from contract_cases import run, source


class LifecycleTests(unittest.TestCase):
    def test_disable_during_boot_wait_exits_without_starting(self):
        result = run(source('engine-state.sh') + '''
execDir=$PWD; n=0
getprop() { echo 0; }
sleep() { n=$((n + 1)); touch disable; }
ng_wait_boot || code=$?
echo "${code:-0}:$n"
ng_print_engine_state | grep engineState=
''')
        self.assertEqual({'code': 0, 'output': '14:1\nengineState=disabled'}, result)

    def test_boot_wait_is_bounded_and_current_boot_status_is_reported(self):
        result = run(source('engine-state.sh') + '''
execDir=$PWD; n=0
getprop() { echo 0; }; sleep() { n=$((n + 1)); }
ng_wait_boot || code=$?
echo "${code:-0}:$n"
ng_print_engine_state | grep engineState=
sed -i 's/^bootId=.*/bootId=previous-boot/' engine-state
ng_print_engine_state | grep engineState=
''')
        self.assertEqual({'code': 0, 'output': '16:150\nengineState=boot-timeout\nengineState=stopped'}, result)

    def test_ready_boot_and_test_flag_are_explicit(self):
        result = run(source('engine-state.sh') + '''
execDir=$PWD; getprop() { echo 1; }; sleep() { exit 99; }
ng_wait_boot; ng_engine_state ready
ng_print_engine_state | grep engineState=
touch .test-active
ng_print_engine_state | grep engineState=
''')
        self.assertEqual({'code': 0, 'output': 'engineState=ready\nengineState=testing'}, result)

    def test_archives_reject_traversal_symlinks_and_foreign_roots(self):
        import base64
        for name, path, kind, accepted in [('safe', 'acc-ng-fixture/module.prop', 'file', True),
                ('traversal', 'acc-ng-fixture/../../outside', 'file', False),
                ('absolute', '/acc-ng-fixture/absolute', 'file', False),
                ('symlink', 'acc-ng-fixture/link', 'link', False),
                ('foreign', 'acc-master/module.prop', 'file', False)]:
            with self.subTest(name=name):
                buffer = io.BytesIO()
                with tarfile.open(fileobj=buffer, mode='w:gz') as tar:
                    info = tarfile.TarInfo(path)
                    if kind == 'link': info.type = tarfile.SYMTYPE; info.linkname = '/data/adb/modules'
                    else: info.size = 7
                    tar.addfile(info, None if kind == 'link' else io.BytesIO(b'id=acc\n'))
                script = source('archive-check.sh') + '\nprintf %s ' + shlex.quote(base64.b64encode(buffer.getvalue()).decode()) + ' | base64 -d > source.tgz\n'
                result = run(script + 'if ng_archive_valid source.tgz; then echo ACCEPT; else echo REJECT; fi')
                self.assertEqual({'code': 0, 'output': 'ACCEPT' if accepted else 'REJECT'}, result)

    def test_rollback_preserves_current_profile_and_keeps_replaced_module(self):
        shell = '/system/bin/sh' if os.environ.get('ACC_TEST_ADB_SERIAL') else 'bash'
        helper = source('rollback.sh').replace('/system/bin/sh', shell).replace('/data/adb/modules/acc|/data/adb/vr25/acc', '"$PWD"/modules/acc|"$PWD"/vr25/acc')
        result = run(helper + '''
mkdir -p modules/acc backup/install-old/module logs
execDir=$PWD/modules/acc
echo 'capacity=(2 101 50 60 false false)' > "$config"; cp "$config" before
printf 'id=acc\nngApiVersion=1\nversionCode=1\n' > backup/install-old/module/module.prop
echo old > backup/install-old/module/runtime; echo new > modules/acc/runtime
''' + 'printf %s ' + shlex.quote('#!' + ('/system/bin/sh' if os.environ.get('ACC_TEST_ADB_SERIAL') else '/bin/bash') + '\necho STARTED\n') + ''' > backup/install-old/module/service.sh
chmod +x backup/install-old/module/service.sh
printf '#!/system/bin/sh\nexit 9\n' > acca
chmod +x acca
''' + ("sed -i '1c#!/bin/bash' acca\n" if not os.environ.get('ACC_TEST_ADB_SERIAL') else '') + '''
ng_rollback "$PWD/backup/install-old"
cmp before "$config"
cat modules/acc/runtime
cat backup/rollback-*/module/runtime
''')
        self.assertEqual({'code': 0, 'output': 'STARTED\nold\nnew'}, result)

    def test_download_uses_tls_http_failure_and_time_limits(self):
        text = (Path(__file__).resolve().parents[1] / 'install-online.sh').read_text()
        start = text.index('ng_download() {'); end = text.index('\n}', start) + 2
        result = run('curl() { printf \'%s\\n\' "$*"; return 22; }\n' + text[start:end] + '''
ng_download https://example.test/module || code=$?
echo "$code"
''')
        self.assertEqual(0, result['code'])
        self.assertIn('--fail --location --proto =https --proto-redir =https --connect-timeout 10 --max-time 120', result['output'])
        self.assertTrue(result['output'].endswith('\n22'))
