GTA V Essentials 1.4.0 for GTA San Andreas 1.0 US

Controller:
- GTA V-style GInput layout 2 remains the base layout.
- RB is the vehicle handbrake and applies motorcycle rear-brake pressure.
- R3 looks behind while driving.
- Hold LB to aim freely from a vehicle; while LB is held, RB fires instead of braking.
- Keyboard handbrake remains available.

Compatibility:
- The engine frame limiter is kept enabled. Framerate Vigilante raises its cap
  to 60 FPS while retaining gym, swimming, driving-school and physics behavior.

Saves:
- This plugin does not hook the save system.
- Use manual safehouse saves. Slot 8 remains reserved for SaveLoader/GTASnP.
- Runtime diagnostics are written to GTAVEssentials.log, with a fallback in the
  game root if the module folder is unavailable.

Safety:
- Hooks are installed only when gta_sa.exe has the supported 1.0 US SHA-256.
- Every requested hook is checked before memory is changed. A failed write rolls
  back any hook installed during the same initialization.

Source code is included under native/GTAVEssentials in the installer repository.
