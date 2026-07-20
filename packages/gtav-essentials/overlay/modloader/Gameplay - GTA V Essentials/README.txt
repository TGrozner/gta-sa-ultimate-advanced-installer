GTA V Essentials for GTA San Andreas 1.0 US

Controller:
- GTA V-style GInput layout 2 remains the base layout.
- RB is the vehicle handbrake.
- R3 looks behind while driving.
- Hold LB to aim freely from a vehicle; while LB is held, RB fires instead of braking.
- Keyboard handbrake remains available.

Autosave:
- A save is written five seconds after the missions-passed counter increases.
- Slot 7 is reserved for autosaves. Slot 8 is intentionally avoided because
  SaveLoader can use it for GTASnP uploads.
- An existing slot 7 is never overwritten unless this module previously created it.
- Runtime diagnostics are written to GTAVEssentials.log.

Source code is included under native/GTAVEssentials in the installer repository.
