# Engine fixtures

Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`.
Linux uses the system shell/tools. On macOS, `host_tools.py` supplies real
file locks and bounded subprocess timeouts, translates the used GNU sed/stat
forms, and detects the zero exit status Apple's Bash 3.2 returns for an
unclosed array during syntax checking. Child fixture scripts inherit these
tools too. Linux and macOS are both checked in CI.

Set `ACC_TEST_ADB_SERIAL=<serial>` to execute the shell fixtures with Android
mksh and the installed BusyBox. These fixtures use generated temporary files,
not live charging controls. Two tests require Android's actual lock behavior;
the host results do not replace that check or physical hardware validation.

The historical preference-write test always runs on the host, even when the
Android runner is selected. It now uses the same portable host tooling.

`test_controller_protections.py` runs the actual controller and protective
helpers against synthetic capacity/voltage/temperature files. It checks charge
cooldown interruption and OFF effects, invalid-data handling, physical shutdown
boundaries and reconnect cancellation, three-attempt control failures and the
two-cycle idle reselection budget. Platform shutdown/control operations are
stubbed; these cases never read or write live sensors. They replace the former
assertions that only searched for control-path source strings.
