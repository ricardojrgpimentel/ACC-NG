# v1.0.7-ng (local candidate, unreleased)

- Preserve installation sources and unrelated files in /data/local/tmp during
  upgrade, recovery and uninstall; remove inherited acc[-_]* staging cleanup.
  Tarball/online callers continue to clean their own extracted source.
- Exercise complete installation/cleanup and failed-copy recovery flows in
  isolated host/Android filesystems; preserve the old module, configuration
  and original failure status. Include installer hashes in bundle provenance.
- Preserve API 1/schema 202310160 and existing charging behaviour. Full R5/R7
  validation and publication remain pending.

# v1.0.6-ng (local candidate, unreleased)

- Discover current/voltage controls without chmod or waiting for a charger;
  preserve per-boot caches/original snapshots and deduplicate node aliases.
- Capture all original control values before any write, including distinct
  sysfs nodes sharing one OEM driver setting.
- Use final upstream discovery blacklist and validate automatic candidates,
  including cached parsed switches and thermal-level references.
- Apply the latest saved request under the frontend lock without queuing stale
  setters; automatic switch writes preserve fresh settings and manual choices.
- Share connected/disconnected/unknown semantics across controller, events and
  generated frontend helper, ignoring internal Battery/BMS/OTG sources.
- Add power-limits-status capability / acca --power-status readback. Applied
  requires successful control writes and matching nodes, not measured current.
- Preserve API 1/schema, manual calibration, profiles and the thermal r suffix.
  Synthetic host/Android validation only; live I3 installation/sysfs pending.

# v1.0.5-ng (candidate, unreleased)

- Declare NG API 1 capabilities and configuration schema separately from release dates.
- Preserve missing/invalid current and voltage as unavailable in frontend info,
  instead of fabricating zero readings. Valid zero remains a measured value.
- Add shared frontend contract fixtures generated from production shell fragments.
  Cover defaults, profile writes/reloads, manual switch, thermal r suffix, global
  preferences, status/test exit codes and milli/micro sensor units.
- Add an opt-in Android runner using temporary files only. Live installation,
  control, upgrade/rollback and reboot validation remain pending.

# v1.0.4-ng (candidate, unreleased)

- Adapt ACC dev's conditional resets: only restore current, voltage and thermal
  controls changed by ACC-NG, using their first observed values.
- Keep current/voltage setters separate from each other and user boot/plug scripts.
- Preserve OEM ownership and permissions; try direct writes first and restore
  any temporary owner-write permission, including on errors.
- Keep failed/partial changes recoverable; verify readback and bound concurrent
  limit operations to a five-second lock wait.
- Exclude battery/store_mode from automatic charging-switch discovery (69cfecb).
- Preserve NG API 1, configuration schema, CLI output and existing protections.
- Add host and Android fixture tests. Live sysfs/upgrade validation is pending.

# v1.0.3-ng

- Fix charger detection during first-install current calibration on Samsung:
  ignore battery/OTG online flags and require an external supply reading.
- Keep calibration conservative when external supply data is unavailable.
- Stop verified orphan calibration workers before releasing the daemon lock;
  bound installer/service lock waits instead of hanging on inherited locks.

v1.0.2-ng (202610092)

- Read the actual GitHub archive root for tagged online installs (GitHub strips v).
- Return online install failures instead of reporting success after cleanup.

v1.0.1-ng (202610091)

- Accept both bundled acc-ng-* and GitHub ACC-NG-* source archive folders.
- Validate the NG API marker before selecting/installing source.
- Fix the source-directory name used by the online updater.

v1.0.0-ng (202610090)

- First ACC-NG engine for AccA-NG, based on ACC v2023.10.16.
- Preserve configurable limits and ACC thermal/cooldown/shutdown protections.
- Add observed state notifications, Portuguese/English notices and bounded logs.
- Identify the fork, use its update channel, preserve dated migration backups.
- Keep module ID acc for one engine and compatible scheduler/runtime paths.

**v2023.10.16 (202310160)**
- "edit g" shall work with non-root apps (acc -h g, acc -l g, acc -la g)
- -f supports additional options (e.g., acc -f -sc 500)
- -h|--help [[editor] [editor_opts] | g for GUI] prints the help text, plus the config
- -sd shall not print user scripts
- accd auto-updates mcc and mcv arrays (missing ctrl files or array[1] "-" marker)
- Added dev tag to update checker
- Additional charging switches
- Additional current control files
- allowIdleAbovePcap=true, if set to false, accd will avoid idle mode (if possible) when capacity > pause_capacity
- Auto-move failing switches to the end of the list
- Default acc -w refresh rate set to 1 second
- Default capacity_sync set to false
- Dropped obsolete code & information
- Ensure charging switch is set before a pause condition is hit
- Fixed html hyperlinks and duplicate temp in acc -i (OnePlus 7)
- Implement "rt ct mt" restricted charging hysteresis
- Improved current control files parsing & automatic switch logic
- KaiOS support
- Log export function invokes Android's share dialog
- Optimized loop delays (loopDelay=(3 9): 3 seconds while charging/idle, 9 seconds while discharging)
- prioritizeBattIdleMode=no has the opposite effect (prioritize non-idle mode)
- Refactored battery health calculator and cooldown logic
- resume_temp and cooldown_temp optionally override resume_capacity (if resume_temp has a trailing "r", as in resume_temp=35r)
- Selection lists count from 0 instead of 1
- Show /dev/ prefix tip only if acc is not in $PATH
- Suspend regular daemon functions until discharge_polarity is set, either automatically or manually
- Updated documentation
- Validate current control files only while charging
- Wizard is more user-friendly

**v2023.8.19 (202308190)**
- 1936210 Fix print_quit error
- 28d68bd Fix -f and temp_level
- 08e2c3f Fix --upgrade
- 6f69b45 Add constant_charge_current* control files
- 312a429 Update resume_temp information
- 2744859 Fix module info updater
- 6dac4a7 resume_temp with trailing r always overrides resume_capacity

**v2023.8.12 (202308120)**
- -H|--health <mAh>: Print estimated battery health
- -r|--readme now sends intent to open README.html
- Additional charging switches
- Fix set_temp_level() sleep 4;
- Fixed one-line scripts identifier
- Fixed random accd crash
- Implemented resume_temp; deprecated max_temp_pause
- Refactored edit handler; use "g" (instead of "app") for GUI editor
- Set default temp_level to null to accommodate battery/siop_level
- Set list number width to 2 columns
