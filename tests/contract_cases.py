"""Run production shell fragments against synthetic files on host or Android."""
import json
import hashlib
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'install' / name).read_text()


def function(filename, name):
    text = source(filename)
    begin = re.search(r'^' + re.escape(name) + r'\(\) \{', text, re.M).start()
    end = text.index('\n}', begin) + 2
    return (source('external-power.sh') + '\n' if name in ('online', 'ng_online') else '') + text[begin:end]


def run(commands):
    script = 'set -eu\nTMPDIR=$PWD; dataDir=$PWD; config=$PWD/config.txt\n' + commands
    serial = os.environ.get('ACC_TEST_ADB_SERIAL')
    with tempfile.TemporaryDirectory(prefix='acc-contract-') as td:
        if not serial:
            result = subprocess.run(['bash', '-c', script], cwd=td, capture_output=True,
                                    text=True, timeout=15)
        else:
            remote = subprocess.check_output(['adb', '-s', serial, 'shell',
                'mktemp -d /data/local/tmp/acc-contract.XXXXXX'], text=True).strip()
            if not remote.startswith('/data/local/tmp/acc-contract.'):
                raise RuntimeError('Unexpected fixture directory')
            path = Path(td) / 'test.sh'
            path.write_text('PATH=/dev/.vr25/busybox:$PATH\ncd ' + shlex.quote(remote) + '\n' + script)
            try:
                subprocess.run(['adb', '-s', serial, 'push', str(path), remote + '/test.sh'],
                               check=True, capture_output=True)
                result = subprocess.run(['adb', '-s', serial, 'shell', 'su -c ' +
                    shlex.quote('/system/bin/sh ' + shlex.quote(remote + '/test.sh'))],
                    capture_output=True, text=True, timeout=20)
            finally:
                subprocess.run(['adb', '-s', serial, 'shell', 'su -c ' +
                    shlex.quote('rm -rf ' + shlex.quote(remote))], check=True, capture_output=True)
        return {'code': result.returncode, 'output': result.stdout.replace('\r\n', '\n').strip()}


def config_case(overrides='', write=False):
    script = source('default-config.txt') + '\n' + overrides + '\n'
    if write:
        script += '''echo 202310160 > .config-ver; touch .config-help "$config"
''' + source('write-config.sh') + '\ncat "$config"; echo ====PRINT====\n. "$config"\n'
    # ns omits user script lines; this is the exact production -sp printer.
    script += 'set -- ns\n' + source('print-config.sh')
    result = run(script)
    if result['code']:
        raise RuntimeError('Configuration fixture failed')
    if write:
        raw, printed = result['output'].split('\n====PRINT====\n')
        return {'raw': raw, 'output': printed}
    return result


def info_case(current='1800000', voltage='4200000', factor='1000000', status='Charging', verbose=False):
    # These are regular files. No real power-supply path is ever used.
    readings = ['POWER_SUPPLY_NAME=main-battery', 'POWER_SUPPLY_STATUS=' + status,
        'POWER_SUPPLY_HEALTH=Good', 'POWER_SUPPLY_PRESENT=1', 'POWER_SUPPLY_CAPACITY=81',
        'POWER_SUPPLY_TEMP=320', 'POWER_SUPPLY_POWER_NOW=7560000', 'POWER_SUPPLY_INPUT_SUSPEND=1',
        'POWER_SUPPLY_INPUT_CURRENT_LIMITED=0', 'POWER_SUPPLY_CURRENT_QNOVO=12345',
        'POWER_SUPPLY_TAPER_CONTROL_ENABLED=0', 'POWER_SUPPLY_CHARGE_DISABLE=1',
        'POWER_SUPPLY_CHARGE_DONE=0', 'POWER_SUPPLY_STEP_CHARGING_ENABLED=1',
        'POWER_SUPPLY_SW_JEITA_ENABLED=0', 'POWER_SUPPLY_PARALLEL_DISABLE=1',
        'POWER_SUPPLY_TECHNOLOGY=Li-ion', 'POWER_SUPPLY_CYCLE_COUNT=42']
    if current is not None:
        readings.append('POWER_SUPPLY_CURRENT_NOW=' + current)
    if voltage is not None:
        readings.append('POWER_SUPPLY_VOLTAGE_NOW=' + voltage)
    script = 'mkdir battery usb\nprintf %s ' + shlex.quote('\n'.join(readings) + '\n') + ' > battery/uevent\n'
    script += 'echo 60 > battery/capacity; echo 325 > battery/temp; echo 0 > usb/online\n'
    script += f'batt=battery; battCapacity=battery/capacity; temp=battery/temp; ampFactor={factor}; ampFactor_={factor}; voltFactor={factor}; verbose={str(verbose).lower()}\n'
    script += 'not_charging() { _status=' + shlex.quote(status) + '; return 0; }\ntt() { return 1; }\n'
    script += 'print_A() { :; }; print_V() { :; }; print_W() { :; }\n'
    return run(script + source('batt-info.sh') + '\nbatt_info | sed "s/=Idle$/=Not charging/"')


def collect():
    fixtures = {'version': {}, 'module': (ROOT / 'module.prop').read_text().strip(), 'config': {}, 'info': {}, 'daemon': {}, 'switch': {}}
    props = dict(line.split('=', 1) for line in fixtures['module'].splitlines() if '=' in line)
    version_body = source('acc.sh').split('  -v|--version)', 1)[1].split(';;', 1)[0]
    fixtures['version']['current'] = run('accVer=' + shlex.quote(props['version']) +
        '; accVerCode=' + shlex.quote(props['versionCode']) + '\n' + version_body)
    fixtures['sources'] = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        for name in ['install.sh', 'install/uninstall.sh', 'install-tarball.sh', 'install-online.sh',
                     'install/acca.sh', 'install/acc.sh', 'install/batt-info.sh',
                     'install/batt-interface.sh', 'install/print-config.sh',
                     'install/default-config.txt', 'install/write-config.sh', 'install/set-prop.sh',
                     'install/external-power.sh', 'install/control-discovery.sh', 'install/ng-power-limits.sh',
                     'install/limit-control.sh', 'install/control-write.sh', 'install/set-ch-curr.sh',
                     'install/set-ch-volt.sh', 'install/accd.sh', 'install/ng-events.sh', 'install/misc-functions.sh', 'install/sensor-discovery.sh', 'install/ctrl-files.sh', 'install/oem-custom.sh', 'install/switch-test.sh', 'install/config-transaction.sh', 'install/engine-state.sh', 'install/service.sh', 'install/diagnostics.sh', 'install/logf.sh', 'install/rollback.sh', 'install/setup-busybox.sh', 'install/archive-check.sh']}
    fixtures['config']['default'] = config_case()
    fixtures['config']['profile'] = config_case('''
ngNotifications=false; ngNotificationLanguage=pt-PT
pause_capacity=60; resume_capacity=50; shutdown_capacity=2
cooldown_capacity=101; resume_temp=40r
chargingSwitch=(battery/charging_enabled 1 0 --)
applyOnBoot=(battery/current_max::500::1800)
applyOnPlug=(battery/voltage_max::4100::4200)
maxChargingCurrent=(500); maxChargingVoltage=(4100)
''', write=True)
    fixtures['config']['voltage-profile'] = config_case('''
capacity=(2 101 3800 3900 true false)
temperature=(35 50 40r 55)
ngNotifications=false; ngNotificationLanguage=pt
''', write=True)
    fixtures['config']['cooldown'] = config_case('capacity=(2 55 50 60 true true); cooldownRatio=(30 5); resetBattStats=(true true true)\n', write=True)
    cases = {
        'micro-charging': {}, 'milli-charging': {'current': '1800', 'voltage': '4200', 'factor': '1000'},
        'discharging': {'current': '750000', 'status': 'Discharging'},
        'idle': {'current': '-4000', 'status': 'Idle'}, 'zero': {'current': '0'},
        'missing-current': {'current': None}, 'malformed-current': {'current': 'unavailable'},
        'missing-voltage': {'voltage': None}, 'malformed-voltage': {'voltage': 'unavailable'},
        'verbose': {'verbose': True}, 'small-micro': {'current': '6000'},
    }
    for name, args in cases.items():
        fixtures['info'][name] = info_case(**args)
    # Execute the frontend daemon-status function, with only its lock result stubbed.
    for name, lock_result in [('running', 1), ('stopped', 0)]:
        fixtures['daemon'][name] = run(f'flock() {{ return {lock_result}; }}\n' +
            function('acca.sh', 'daemon_ctrl') + '\ndaemon_ctrl')
    # Execute the bounded production probe with file-backed switch/status data.
    for name, status in [('working', 'Discharging'), ('idle', 'Idle'), ('failed', 'Charging')]:
        script = source('switch-test.sh') + '\n' + function('misc-functions.sh', 'parse_value') + """
mkdir battery; echo 1 > battery/charging_enabled
ng_test_snapshot=$PWD/snapshot; ng_test_deadline=45
echo 300 > temp; temp=$PWD/temp; temperature=(35 50 40r 55)
ng_telemetry_valid() { return 0; }
ng_test_time() { echo 0; }; sleep() { :; }
write_control() { printf '%s\\n' "$1" > "$2"; }
print_switch_works() { echo 'Switch works'; }
"""
        script += 'offStatus=' + shlex.quote(status) + """
flip_sw() { if [ "$1" = off ]; then _fixtureStatus=$offStatus; else _fixtureStatus=Charging; fi; }
not_charging() { _status=$_fixtureStatus; [ "$_status" != Charging ]; }
ng_test_switch battery/charging_enabled 1 0
"""
        fixtures['switch'][name] = run(script)
    fixtures['switch']['list'] = run("printf '%s\\n' 'battery/charging_enabled 1 0' 'battery/batt_slate_mode 0 1 --' > ch-switches\n" +
        function('set-prop.sh', 'set_prop') + '\nset_prop s:')
    fixtures['daemon']['already-running'] = run('flock() { return 1; }; print_already_running() { echo "Already running"; }\n' +
        function('acc.sh', 'daemon_ctrl') + '\ndaemon_ctrl start')
    fixtures['power-limits'] = {}
    for name in ['pending', 'unsupported', 'applied', 'drift', 'off', 'failed']:
        script = source('external-power.sh') + source('control-discovery.sh') + source('ng-power-limits.sh')
        script += '\nmkdir battery usb; echo 1 > usb/online; echo 500 > battery/current_max\n'
        script += 'maxChargingCurrent=(500); maxChargingVoltage=()\n'
        if name != 'pending':
            script += 'touch .ch-curr-read; echo battery/current_max::v::1800 > ch-curr-ctrl-files\n'
        if name == 'unsupported': script += ': > ch-curr-ctrl-files\n'
        if name in ['applied', 'drift']: script += 'ng_limit_result current 500 applied\n'
        if name == 'drift': script += 'echo 700 > battery/current_max\n'
        if name == 'failed': script += 'ng_limit_result current 500 failed\n'
        if name == 'off': script += 'maxChargingCurrent=()\n'
        fixtures['power-limits'][name] = run(script + 'ng_print_power_limits')
    return fixtures


def serialized():
    return json.dumps(collect(), indent=2, ensure_ascii=False) + '\n'
