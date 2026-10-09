# ACC-NG — Advanced Charging Controller NG

Charging engine for [AccA-NG](https://github.com/ricardojrgpimentel/ACCA-NG).
Maintained by Ricardo Pimentel. Fork of [VR25/ACC](https://github.com/VR-25/acc),
based on the tested `v2023.10.16` release (`f3d6eb0f5697c3d2e401097e9b5b6b8370bac1b2`), with its original GPLv3+ license.

## What this version does

- Applies pause/resume, temperature, current, voltage and idle settings from AccA-NG.
- Keeps the original ACC control loop, cooldown and thermal/shutdown protections.
- Adds charging-state, connection, temperature and low-battery events, inspired
  by Ian7672's notifications. No fixed 90%/80% thresholds or percentage-based idle claims.
- Events observe the ACC battery/current interface and physical power-supply
  `online` readings. Notifications cannot block or change charging control.
- Keeps a bounded diagnostic event log and optional Portuguese/English notices.
- Uses this fork's update channel and identifies itself as ACC-NG in Magisk.

The Magisk ID remains `acc` and runtime paths remain `/data/adb/vr25/acc*` so
migration replaces the old engine and existing configuration/scheduler paths
continue to work. Do not install a second charging controller alongside it.
A normal Magisk uninstall still removes ACC runtime configuration; back it up first.

## Build and tests

```sh
python3 -m unittest discover -s tests -v
python3 tools/build_ng.py
```

Outputs: a flashable ZIP and a reproducible installable tarball in `_builds/`.
The tarball bundled with AccA-NG is produced by this same script.

## Configuration and migration

The upstream configuration schema stays `202310160`. NG module releases have
separate `versionCode`, `ngApiVersion` and `upstreamVersionCode` metadata.
Installers preserve settings and keep dated module/config snapshots in
`/data/adb/vr25/acc-data/backup/install-*`. Validate a device backup before migrating.

`acca -s ng_notifications=false` disables the additional notices without disabling
charging control or existing critical ACC warnings. `ng_notification_language`
accepts `en`, `pt`, `pt-PT`, `pt-BR`. AccA-NG exposes the switch and sets notice
language to match its UI. Saved profiles preserve these global engine preferences.

## Origin and credits

- VR25: original ACC engine and device compatibility database.
- Ricardo Pimentel: ACC-NG maintenance and integration with AccA-NG.
- Ian7672: inspiration for additional charging notifications. The event logic is
  independently implemented; the fixed limits and removed protection logic are not adopted.

See [the original documentation](README.upstream.md) for ACC's supported controls.
Changes after upstream v2023.10.16 require separate device compatibility review.
The v1.0.4-ng candidate selectively adapts limit ownership/reset handling and
excludes store_mode; the upstream schema/API changes are not included. See
[the integration record](docs/upstream-integration.md).


Candidate builds write update metadata under `_builds/` and leave the published
`module.json` unchanged. Use `python3 tools/build_ng.py --update-metadata` only
when preparing publication with matching release assets; a source push alone
must not advertise candidate download URLs.
