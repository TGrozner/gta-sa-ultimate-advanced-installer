GTA V Essentials for GTA San Andreas 1.0 US

Controller:
- GTA V-style GInput layout 2 remains the base layout.
- RB is the vehicle handbrake and applies motorcycle rear-brake pressure.
- R3 looks behind while driving.
- Hold LB to aim freely from a vehicle; while LB is held, RB fires instead of braking.
- Keyboard handbrake remains available.

Compatibility:
- The engine frame limiter is kept enabled. Framerate Vigilante raises its cap
  to 60 FPS while retaining gym, swimming, driving-school and physics behavior.

Autosave:
- A save is scheduled five seconds after the missions-passed counter increases.
- Writing waits until the mission thread/cutscene has ended, CJ is on foot, no
  gang war is running, the menu is closed and player controls have stayed
  available for ten continuous seconds.
- The result is validated before replacing the previous autosave, and its resume
  location comes from the most recently used manual safehouse save.
- The matching CLEO state is written to the same save slot.
- Slot 7 is reserved for autosaves. Slot 8 is intentionally avoided because
  SaveLoader can use it for GTASnP uploads.
- An existing slot 7 is never overwritten unless this module previously created it.
- Runtime diagnostics are written to GTAVEssentials.log, with a fallback in the
  game root if the module folder is unavailable.

Source code is included under native/GTAVEssentials in the installer repository.
