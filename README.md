# uperf-12x

Uperf-12X custom build for Snapdragon 8 Elite Gen5 (8EG5 / SM8850), focused on battery-efficient smoothness.

## Current module version

- `2026.04.18.21`

## Included in this repo

- 8EG5 scheduler profile: `config/sdm8g5.json`
- Per-app policy template: `config/perapp_powermode.txt`
- Closed-loop controller: `script/closedloop_sched.sh`
- Runtime scripts and installer layout for Magisk/KernelSU packaging
- Attribution and modification notes: `REFERENCES_AND_MODIFICATIONS_12X.md`

## Important note about prebuilt binaries

This repo currently does **not** include prebuilt runtime binaries:
- `bin/uperf`
- `bin/busybox/busybox`

See `bin/README.md` for details.

## Upstream base and attribution

- Upstream project: [yc9559/uperf](https://github.com/yc9559/uperf)
- Detailed references and modification log: `REFERENCES_AND_MODIFICATIONS_12X.md`
