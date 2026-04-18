# Uperf-12X References and Modifications

Date: 2026-04-18 21:00
Author: 12X

## Upstream References

- Base project: `yc9559/uperf`
- Upstream URL: `https://github.com/yc9559/uperf`
- Upstream release base: `dev-22.09.04`
- License references:
  - Project license: `LICENSE` (Apache-2.0)
  - Third-party notices: `NOTICE` (includes BusyBox GPLv2 notice)

## What Was Modified in This Build

This package is a derivative tuning build based on upstream release files.

1. Platform support
   - Added 8EG5 mapping in `script/libsysinfo.sh`
   - Added install-time fallback detection for `sm8850|kaanapali` in `script/setup.sh`
   - Added 8EG5 config file `config/sdm8g5.json`

2. 8EG5 power/scheduler tuning
   - Tuned `powerModel` and CPU governor strategy for battery-first behavior
   - Tuned scene presets (`balance/powersave/performance/fast/crazy`) with lower `margin/burst`
   - Retuned CPU policy using a tail-latency-first approach (`P95/P99 frame stability` under `energy budget`):
     - lower sustained power envelope in `idle/touch`
     - short bounded burst in `trigger/switch/junk`
     - dynamic cpuset `0-6` default and short `0-7` escape for startup/jank recovery
   - Added scene-aware GPU devfreq control (`/sys/class/kgsl/kgsl-3d0/devfreq/min_freq|max_freq`) in `config/sdm8g5.json`
   - Coordinated CPU+GPU tuning for app launch burst and low-power video/background playback
   - Added runtime GPU node auto-detection in `script/initsvc.sh`:
     - Prefer writable `devfreq/min_freq|max_freq` nodes
     - Fallback to `/dev/null` when only read-only telemetry nodes are exposed
   - Added full installed-app auto scheduling in `script/initsvc.sh`:
     - Enumerates all packages at boot (`cmd package list packages`/`pm list packages`)
     - Regenerates `perapp_powermode.txt` with explicit mode for every installed app
     - Uses `powersave` for known video apps and `balance` for other apps
     - Keeps `- powersave` and `* balance` defaults to avoid any coverage gap
   - Added frame-target closed-loop controller in `script/closedloop_sched.sh`:
     - Joint score: `tail latency + energy` (P95/P99 frame tail and CPU cost proxy)
     - Baseline phase-1: start at boot+2min, sample every 1min for 30 rounds
     - Baseline phase-2: after phase-1, sample every 3min only when screen is off for 50 rounds
     - Uses phase-1 baseline until phase-2 reaches target rounds, then switches to phase-2 final baseline
     - Records every app switch with cost and every in-app `balance/powersave` switch
     - Stores events in ring-style log with max 5000 records (`closedloop_events.csv`)
   - Adjusted hint durations to reduce high-frequency hold time
   - Adjusted affinity/cpuset defaults to reduce unnecessary prime-core usage
   - Added an `AsoulOpt Games` scheduler rule in `config/sdm8g5.json`:
     - Ported game package matching list from `nakixii/Magisk_AsoulOpt` release `Evil`
     - Ported common game-thread priority/affinity strategy into uperf `sched.rules`
     - Integrated as config-only logic (did not bundle/run AsoulOpt binary daemon)

3. Module identity and metadata
   - Name changed to `Uperf-12X`
   - Version changed to `2026.04.18.21`
   - Author changed to `12X`
   - Removed update links (`updateJson`, `projectUrl`, installer URL line)

4. Default policy
   - Default init mode set to `balance` in `script/powercfg_main.sh`
   - Per-app defaults: offscreen `powersave`, default app mode `balance` in `config/perapp_powermode.txt`
   - Added common video app list mapped to `powersave` in `config/perapp_powermode.txt`

## Notes

- `bin/uperf` and `bin/busybox/busybox` are binary files from the module base package.
- This build focuses on 8EG5 support and battery-oriented scheduling behavior.
