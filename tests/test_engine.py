import pathlib, subprocess, tempfile, unittest
from host_tools import run_host
ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON = (ROOT/'install/accd.sh').read_text()

def function(name):
    start = DAEMON.index('  '+name+'() {')
    end = DAEMON.index('\n  }', start) + len('\n  }')
    return DAEMON[start:end]

class EngineTests(unittest.TestCase):
    def run_shell(self, script):
        result = run_host('set -eu\n' + script, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout.splitlines()

    def control(self, charging, level=65, temperature=300, pause=60, resume=50):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);(p/'cap').write_text(str(level));(p/'temp').write_text(str(temperature))
            script=f'TMPDIR={td}; battCapacity={td}/cap; temp={td}/temp; capacity=(2 101 {resume} {pause} false false); temperature=(35 50 45 55); loopDelay=(1 1); offMid=false; allowIdleAbovePcap=true; resetBattStats=(false false false); cooldownRatio=(); cooldownCustom=(); cooldown=false\n'
            script+='execDir=$TMPDIR; ng_engine_state() { :; }; ng_telemetry_valid() { return 0; }; t() { test "$@"; }; tt() { return 1; }; volt_now() { echo 3900; }; ng_observe() { return 0; }; ng_power_state() { return 0; }; force_off() { :; }; ng_disable_safe() { disable_charging; }; disable_charging() { echo OFF; }; enable_charging() { echo ON; }; sleep() { exit 0; }; _uptime() { return 1; }; not_charging() { return 1; }; is_charging() { '+('return 0' if charging else 'return 1')+'; };\n'
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
            script=f'cd {td}; execDir={ROOT}/install; TMPDIR={td}; dataDir={td}; battCapacity=battery/cap; temp=battery/temp; capacity=(2 101 50 60 false false); temperature=(35 50 45 55)\n'
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

    def test_controller_online_ignores_battery_enum_and_otg(self):
        source=(ROOT/'install/batt-interface.sh').read_text()
        start=source.index('online() {');end=source.index('\n}',start)+len('\n}')
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td)
            for name,value in [('battery','1'),('otg','1'),('usb','0')]:
                (p/name).mkdir();(p/name/'online').write_text(value)
            script=f'cd "{td}"; '+(ROOT/'install/external-power.sh').read_text() + '\n' + source[start:end]
            self.assertEqual(['OFFLINE'],self.run_shell(script+'; if online; then echo ONLINE; else echo OFFLINE; fi'))
            (p/'usb/online').write_text('1')
            self.assertEqual(['ONLINE'],self.run_shell(script+'; if online; then echo ONLINE; else echo OFFLINE; fi'))
            (p/'usb/online').unlink()
            self.assertEqual(['UNKNOWN_HELD'],self.run_shell(script+'; if online; then echo UNKNOWN_HELD; fi'))

    def test_lock_cleanup_signals_only_verified_daemon_workers(self):
        for filename in ['uninstall.sh','release-lock.sh']:
            source=(ROOT/'install'/filename).read_text()
            start=source.index('stop_daemon_holders() {')
            end=source.index('\n}',start)+len('\n}')
            with tempfile.TemporaryDirectory() as td:
                p=pathlib.Path(td)
                commands={101:b'sh\0/data/adb/vr25/acc/accd.sh\0',
                    102:b'/system/bin/sh\0/data/adb/modules/acc/accd.sh\0',
                    103:b'sh\0-c\0echo /accd.sh\0',104:b'sh\0/data/adb/modules/other/accd.sh\0'}
                for pid,cmd in commands.items():
                    (p/str(pid)).mkdir();(p/str(pid)/'cmdline').write_bytes(cmd)
                helper=source[start:end].replace('/proc/',td+'/')
                script='pgrep() { echo "101 102 103 104"; }; sleep() { :; }; kill() { echo "$*"; }; '+helper+'; stop_daemon_holders'
                self.assertEqual(['-TERM 101','-TERM 102','-KILL 101','-KILL 102'],self.run_shell(script))

    def test_thermal_and_low_battery_notifications_are_deduplicated(self):
        out=self.events('echo 1 > usb/online; ng_observe Charging; echo 360 > battery/temp; ng_observe Charging; ng_observe Charging; echo 510 > battery/temp; ng_observe Charging; ng_observe Charging; echo 0 > usb/online; echo 19 > battery/cap; ng_observe Discharging; echo 18 > battery/cap; ng_observe Discharging')
        self.assertEqual(['connected:Charger connected','warm:Battery reached configured cooldown temperature','hot:Battery reached configured temperature limit','disconnected:Charger disconnected','low:Battery low: 19%'],out)

    def test_disabled_notifications_still_record_diagnostics(self):
        with tempfile.TemporaryDirectory() as td:
            pathlib.Path(td,'logs').mkdir()
            self.run_shell(f'execDir={ROOT}/install; dataDir={td}; ngNotifications=false; . {ROOT}/install/ng-events.sh; ng_emit low "Battery low: 19%" "Bateria fraca: 19%"')
            self.assertIn('low Battery low: 19%',pathlib.Path(td,'logs/ng-events.log').read_text())

    def test_non_percent_limits_and_state_are_observable(self):
        self.assertIn('paused:Charging paused at configured limit: 3900mV',self.events('capacity=(2 101 3800 3900 false false); echo 1 > usb/online; ng_observe Charging; ng_pause_reason=limit; ng_observe Discharging'))

    def test_bundled_and_github_archives_select_the_ng_source(self):
        import tarfile, io
        installer=(ROOT/'install-tarball.sh').read_text()
        start=installer.index('select_source() {')
        end=installer.index('\n}',start)+len('\n}')
        select=installer[start:end]
        for folder in ['acc-ng-v1.0.2-ng','ACC-NG-main','ACC-NG-1.0.2-ng']:
            with tempfile.TemporaryDirectory() as td:
                archive=pathlib.Path(td)/'source.tgz'
                with tarfile.open(archive,'w:gz') as tar:
                    for name,data in [('module.prop',b'id=acc\nngApiVersion=1\n'),('install.sh',b'#!/bin/sh\n')]:
                        info=tarfile.TarInfo(folder+'/'+name);info.size=len(data);tar.addfile(info,io.BytesIO(data))
                with tarfile.open(archive) as tar:tar.extractall(td,filter='data')
                self.assertEqual([folder],self.run_shell(f'cd {td}; '+select+'; select_source'))
                if folder.startswith('ACC-NG-'):
                    online=(ROOT/'install-online.sh').read_text()
                    begin=online.index('archive_source() {')
                    end=online.index('\n}',begin)+len('\n}')
                    self.assertEqual([folder],self.run_shell(online[begin:end]+f'; archive_source {archive}'))

    def test_global_ng_preferences_survive_profile_writes(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);(p/'.config-ver').write_text('202310160');(p/'.config-help').write_text('')
            script=f'TMPDIR={td}; config={td}/config; touch "$config"; . {ROOT}/install/default-config.txt; ngNotifications=false; ngNotificationLanguage=pt-PT; pause_capacity=60; resume_capacity=50; . {ROOT}/install/write-config.sh; grep -E "^(capacity|ngNotifications|ngNotificationLanguage)=" "$config"'
            self.assertEqual(['ngNotifications=false','ngNotificationLanguage=pt-PT','capacity=(5 50 50 60 false false)'],self.run_shell(script))
