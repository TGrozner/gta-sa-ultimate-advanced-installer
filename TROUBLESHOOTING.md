# Troubleshooting

## The installer reports an incomplete package set

The default profile is intentionally all-or-nothing. Run
`Get-ModSources.ps1 -Prepare`, fill every required overlay from its recorded
source, then run `Lock-Packages.ps1` after reviewing the files. Do not use
`-AllowIncompleteProfile` for a real playthrough.

## A package-lock hash does not match

Stop and compare the archive against its upstream source and version. A changed
hash can mean a legitimate upstream rebuild, an extraction mistake, local
modification or tampering. Regenerate the lock only after identifying the
cause.

## An overlay collision is reported

Two packages want to write different bytes to one destination. Do not choose a
winner blindly. Remove the duplicate component or document one narrowly scoped
path in `allowedOverlayConflicts` with the intended winning package.

## Loading freezes before completion

1. Press F8 if the game was started by `Launch-GTA.ps1`.
2. Run `Test-Installation.ps1` and resolve every failure.
3. Confirm the active profile is `Advanced2026`.
4. Remove Proper Shaders, ImVehFt, ENB, ReShade, RenderHook and root graphics
   wrappers such as `d3d9.dll`.
5. Move aside only the path-specific Mod Loader cache reported under
   `%LOCALAPPDATA%\modloader`.
6. Test both a save load and New Game across two cold starts.

## GTA V-style drive-by is unavailable

Verify that Manual DriveBy Refixed exists and that the validator reports these
settings as correct: GInput `ControlsSet=2`, `DrivebyControlType=5`, and
`DisableOnMission=0`. Type `MDRRELOAD` in game after editing the drive-by INI.

## F8 does nothing

Start the game through `Launch-GTA.ps1`. A healthy
`Tools\f8-kill-switch.log` entry contains `READY pid=<number>`. `REGISTER_FAILED`
usually means another application already owns the global F8 hotkey. The
watcher exits automatically with the exact game process it tracks.

## GTA V Essentials reports an unsupported executable

The ASI verifies the complete `gta_sa.exe` SHA-256 before touching memory. Use
the clean 1.0 US executable listed in `manifest/profile.json`; do not bypass the
native check for another game build because every hook address is version
specific.

## Restore refuses because files changed

Review the listed files first. Copy any edits you want to keep, then rerun
`Restore-Installation.ps1` with `-Force`. Restore verifies every original backup
hash before writing and can be retried if an earlier restore was interrupted.

## Startup crash involving ImVehFt

ImVehFt is deliberately forbidden in this profile. Use the selected VehFuncs +
GSX path. RVP remains optional because its upstream build may still expect
ImVehFt; validate it separately before keeping it enabled.
