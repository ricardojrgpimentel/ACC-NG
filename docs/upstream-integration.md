# First ACC dev integration increment

Candidate: v1.0.4-ng (202610094), unreleased. Based on NG 3d2dbe2 and ACC
v2023.10.16. The reviewed upstream endpoint is 908a5a4; this is not a merge
of that branch. NG API 1 and configuration schema 202310160 stay unchanged.

The full review, per-commit decisions and pending work are maintained in
[AccA-NG docs](https://github.com/ricardojrgpimentel/ACCA-NG/blob/main/docs/acc-upstream-roadmap.md).

| Origin | Applied scope | Remaining scope |
| --- | --- | --- |
| 39a2208, 4b1bfd4 | Restore current/voltage/thermal controls only when owned, once; snapshot actual values | Live OEM control and upgrade validation |
| eaa0c4d | Separate setters from other limits and boot/plug scripts | Remaining daemon-loop optimisations |
| 4999c63 | Replace forced ownership/world-write changes with direct write then temporary u+w and restoration | Live sysfs permission validation |
| 69cfecb | Exclude store_mode from built-in automatic candidates | Upstream release metadata intentionally replaced by NG |

`install/limit-control.sh` serialises each kind of limit with a five-second
flock budget, retains snapshots for failed resets and reports failed readback.
An unchanged refused write does not acquire ownership; a changed node with
failed readback retains its snapshot for recovery. Snapshots live in the
volatile runtime directory and persist across daemon restarts within a boot.
Resetting an absent snapshot does not discover sensors or wait for a charger.
Manual/plugin switch overrides are preserved.

Test with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
ACC_TEST_ADB_SERIAL=<serial> PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p test_limits.py -v
```

The opt-in Android runner uses root, mksh and the installed BusyBox. It writes
only generated files below /data/local/tmp and removes them after each test.
Host tests shim platform-specific tools; real lock contention tests require
Android. No module installation or real charging-control writes are part of
these fixtures. Before release, validate upgrade/rollback, live controls and
OEM thermal behaviour. Frontend confirmation of actual hardware application
(R1.4), broader sensor discovery, migrations and optional features remain pending.
