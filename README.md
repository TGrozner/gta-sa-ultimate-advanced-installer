# GTA SA Ultimate Advanced — installer recipe

This repository builds a reproducible, auditable mod profile for a legal copy
of GTA San Andreas Classic PC. It records each upstream source, locks the exact
files prepared locally, installs them transactionally, validates the result,
and can restore every overwritten file byte-for-byte.

The stable renderer path is **SkyGfx 4.2b + SkyGrad**. Proper Shaders, ImVehFt,
duplicate texture packs, duplicate vehicle textures and competing audio packs
are excluded from the default profile because they overlap or destabilize this
stack.

## Safety model

- GTA SA and third-party mod archives are never redistributed.
- The installer accepts only overlays recorded in `manifest/packages.lock.json`.
- Every locked file is checked by path, size and SHA-256 before installation.
- Different packages may not write different bytes to the same path unless an
  explicit winner is declared in the profile.
- All destination files are backed up before the first mutation. A failure
  triggers an automatic rollback.
- A completed transaction has an immutable backup and a JSON receipt under
  `<game>\_installer-transactions\<transaction-id>`.
- Restore refuses to overwrite files changed since installation unless you
  explicitly use `-Force`.
- The bundled ASI refuses to hook anything except the supported GTA SA 1.0 US
  executable hash.

Read [DISCLAIMER.md](DISCLAIMER.md) before sharing any package or build.

## Requirements

- Windows 10 or 11;
- PowerShell 7 recommended; Windows PowerShell 5.1 supported;
- a legal, clean GTA San Andreas Classic PC installation;
- GTA SA 1.0 US with the SHA-256 listed in `manifest/profile.json`;
- enough free space for the game, archives and transaction backups.

## 1. Prepare the sources

```powershell
.\Get-ModSources.ps1 -Prepare
```

Each generated `packages\<id>` directory contains the original source URL,
version, license notes and expected destination. Download from that source,
review the archive, then place only the installable files under `overlay`,
relative to the game root:

```text
packages/
  skygfx/
    overlay/
      modloader/
        Graphics - SkyGfx 4.2b/
          skygfx.asi
          skygfx1.ini
```

Manual source pages can be opened explicitly:

```powershell
.\Get-ModSources.ps1 -Id skygfx,proper-fixes -OpenManualPages
```

RoSA and Proper Fixes have restrictive redistribution terms. Keep their files
local and never commit them or attach them to a release.

## 2. Lock the reviewed overlays

After checking every archive and its placement:

```powershell
.\Lock-Packages.ps1
git diff -- manifest/packages.lock.json
```

The lock is the trust boundary. Do not regenerate it merely to silence a hash
error: first verify why the prepared archive changed.

## 3. Preview and install

The default installer requires the whole stable profile. It does not perform a
partial “best effort” installation.

```powershell
.\Install.ps1 -GamePath "C:\Games\GTA San Andreas" -WhatIf
.\Install.ps1 -GamePath "C:\Games\GTA San Andreas"
```

`-AllowIncompleteProfile` exists only for package development and automated
tests. It is not a validated gameplay configuration.

## 4. Verify and launch

```powershell
.\Test-Installation.ps1 -GamePath "C:\Games\GTA San Andreas"
.\Launch-GTA.ps1 -GamePath "C:\Games\GTA San Andreas"
```

The verifier checks actual file content, non-empty modules, active Mod Loader
profile, priority rules, forbidden wrappers and the final hashes stored in the
latest transaction receipt.

Launch through the supplied script to enable the F8 emergency stop. The watcher
is tied to the exact PID and executable path started by that launcher; pressing
F8 cannot terminate an unrelated `gta_sa.exe` instance.

## Restore an installation

Restore the newest completed transaction:

```powershell
.\Restore-Installation.ps1 -GamePath "C:\Games\GTA San Andreas"
```

Or select a receipt explicitly:

```powershell
.\Restore-Installation.ps1 -GamePath "C:\Games\GTA San Andreas" -TransactionId "20260721-120000-000-ab12cd34"
```

Backups are retained after restoration so the receipt remains auditable. Empty
directories created by installed packages may remain, but installed files are
removed and replaced files are restored byte-for-byte.

## Selected profile

The required core contains the loader stack, CLEO/CLEO+, limit and streaming
fixes, SkyGfx/SkyGrad/Project2DFX, RoSA 1.5, Proper Fixes 2.1.1, the selected
gameplay and audio fixes, SaveLoader, RepairGTA and the repository-owned GTA V
Essentials plugin. Proper Fixes has a higher Mod Loader priority than RoSA;
Project Props overrides only the companion Buildings Upgrade module.

Ragdoll, RVP, Enterable Hidden Interiors, TruckTrailer, French localization and
4K loadscreens are optional and produce verifier warnings when enabled. Their
reasons and dependencies are recorded in `manifest/profile.json`.

Explicit exclusions include:

- Proper Shaders 05-26, ImVehFt and Wheel Detach;
- AI Upscaled Weapon Textures, Original Peds Vary and Proper Vehicles Retex,
  which duplicate selected RoSA content;
- Uncompressed SFX, which overlaps the selected Soundize stack;
- root DXVK, ENB, ReShade and RenderHook wrappers.

## Controls and saves

- GInput control set 2 remains the base controller layout.
- Vehicle `RB` is the handbrake/rear motorcycle brake; `R3` looks behind.
- Hold `LB` and press `RB` for the selected drive-by controls.
- Framerate Vigilante targets 60 FPS while GTA's engine limiter remains on.
- GTA V Essentials does not hook or emulate saving. Use normal safehouse saves;
  slot 8 remains reserved for SaveLoader/GTASnP.

Runtime diagnostics are written beside `GTAVEssentials.asi`, with a fallback
log in the game root. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for recovery
steps.
