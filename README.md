# GTA SA Ultimate Advanced — installer recipe

A reproducible Windows installer recipe for the validated **GTA SA Ultimate
Advanced 2026** profile. The target is a heavily modernized GTA San Andreas
Classic build that still loads saves and starts new games reliably.

The validated renderer is **SkyGfx 4.2b + SkyGrad**. Proper Shaders 05-26 is
intentionally excluded because it caused intermittent freezes during save and
new-game loading after a cold restart.

## What this repository does

- lists every original mod source and expected module;
- prepares a package workspace with the correct target folders;
- installs package overlays into a legal GTA SA copy with a timestamped backup;
- applies the validated 60 FPS, GInput and GTA V-style drive-by settings;
- installs a global F8 emergency kill switch and launcher;
- detects missing modules, duplicate renderers and known crash combinations.

It does **not** redistribute GTA SA or third-party mod assets. Read
[DISCLAIMER.md](DISCLAIMER.md) before publishing packages or releases.

## Requirements

- Windows 10 or 11;
- PowerShell 7 (`pwsh`) recommended, Windows PowerShell 5.1 supported;
- a legal GTA San Andreas Classic PC installation;
- approximately 40 GB free for the game, downloaded archives and backups;
- GTA SA 1.0 US executable expected by the validated profile.

## Quick start

Open PowerShell in the cloned repository:

```powershell
.\Get-ModSources.ps1 -Prepare
```

For every created package directory, download the mod from `SOURCE.url` and
extract its installable files under `overlay`. The content of `overlay` is
always relative to the game root. Example:

```powershell
.\Get-ModSources.ps1 -Id skygfx,proper-fixes -OpenManualPages
```

```text
packages/
  skygfx/
    overlay/
      modloader/
        Graphics - SkyGfx 4.2b/
          skygfx.asi
          skygfx1.ini
```

Preview the installation without writing:

```powershell
.\Install.ps1 -GamePath "C:\Games\GTA San Andreas" -WhatIf
```

Install available overlays and apply the validated configuration:

```powershell
.\Install.ps1 -GamePath "C:\Games\GTA San Andreas"
```

Verify and launch:

```powershell
.\Test-Installation.ps1 -GamePath "C:\Games\GTA San Andreas"
.\Launch-GTA.ps1 -GamePath "C:\Games\GTA San Andreas"
```

Press **F8** at any time to terminate a frozen `gta_sa.exe` process.

## Important controls

- controller drive-by: GInput layout 2, `LB` aims and `RB` shoots;
- keyboard/mouse drive-by: right mouse button aims;
- type `MDRRELOAD` during gameplay after editing drive-by settings;
- SkyGfx preset 1 uses PS2 building and vehicle pipelines;
- engine frame limit: 60 FPS.

## Package preparation

`Get-ModSources.ps1 -Prepare` creates one folder per manifest entry. GitHub is
used only for this installer repository; third-party archives stay ignored by
Git and must not be pushed.

The installer copies only overlays that exist. It reports absent packages, then
the verifier tells you exactly which modules are still missing. This makes it
possible to build the profile in several passes without losing existing work.

## Safety and rollback

Before overwriting a file, the installer saves the old version under:

```text
<game>\_installer-backups\yyyyMMdd-HHmmss\
```

The installer refuses to run while GTA is open. It never deletes game files.
Use `-WhatIf` to inspect every planned operation.

## Validated exclusions

- Proper Shaders 05-26: intermittent loading freeze;
- ImVehFt 2.1.1: reproducible startup crash `0xc0000417`;
- Wheel Detach: overlaps the selected vehicle stack;
- DXVK, ENB, ReShade and RenderHook: not part of the validated profile;
- duplicate handling files and duplicate limit adjusters.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) when a loading bar stops before
completion or a renderer warning appears.
