# Troubleshooting

## Loading bar freezes before completion

1. Press F8 to stop GTA.
2. Run `Test-Installation.ps1`.
3. Confirm that SkyGfx, SkyGrad and Proper Fixes are all present.
4. Remove Proper Shaders, ENB, ReShade, RenderHook and root `d3d9.dll` wrappers.
5. Clear only the path-specific Mod Loader cache reported in
   `%LOCALAPPDATA%\modloader`; move it aside instead of deleting it.
6. Retry a save and New Game, then perform a second cold restart.

One successful launch is not sufficient: Proper Shaders passed once and failed
again on the following cold launch in the reference build.

### Full bar with RoSA Evolved

The validated GTA SA executable is the 5,189,632-byte 1.0 US Compact build.
RoSA's legacy `ImgLimitAdjuster.asi` and replacement
`SimpleLimitAdjuster_IMGfiles.asi` both crashed that executable during the
reference diagnosis. Do not leave either file active.

Use fastman92 Limit Adjuster 7.6 with the repository INI instead. It raises the
IMG archive count to 64 and the archive-size limit to 32 GB without enabling
the enhanced-IMG hook that conflicted with Mod Loader. Keep Open Limit Adjuster
and Improved Streaming at 1024 MB. `Test-Installation.ps1` checks the binaries,
settings, incompatible adjusters and the complete RoSA payload.

## Proper Fixes warning

Proper Fixes requires a compatible building/map pipeline. The validated profile
uses SkyGfx with `buildingPipe=PS2`. Do not run Proper Fixes without SkyGfx or a
supported alternative renderer.

## GTA V-style drive-by is unavailable

Check:

- `Controls - Manual DriveBy Refixed` exists;
- GInput `ControlsSet=2`;
- `DrivebyControlType=5`;
- `DisableOnMission=0` if you want it during missions.

Type `MDRRELOAD` in game after changing the INI.

## F8 does nothing

Launch the game through `Launch-GTA.ps1`. The watcher writes
`Tools\f8-kill-switch.log`; a healthy start contains `READY_REGISTERED`.

## Startup crash in ImVehFt

ImVehFt 2.1.1 produced exception `0xc0000417` in the validated environment. It
is deliberately forbidden by the verifier. VehFuncs + GSX provides the selected
vehicle extension path instead.

