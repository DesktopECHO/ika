# Desktop Windowing Policy

LineageOS Desktop is a desktop-mode-only tablet product. Tablet identity is part
of app compatibility; handheld launcher and windowing behaviors are treated as
compatibility fallbacks, not as primary UI.

Runtime rules:

- The default display enters desktop/freeform mode at boot.
- Apps launch as freeform desktop windows whenever the framework allows it.
- Taskbar app clicks focus, restore, or open desktop windows.
- Taskbar app clicks must not enter split-select while desktop taskbar mode is
  active.
- App pairs are not a desktop launch primitive. When invoked from the desktop
  taskbar, each member opens as a desktop app instead of creating a split pair.
- Pressing Home keeps the user in the desktop session instead of collapsing back
  to a phone-style home grid.
- Drag-to-top maximization is allowed only when it does not exit the desktop
  session.
- Resize and freeform compatibility flags are reapplied on every boot.

Source ownership:

- Product and property defaults live in `config/desktop_windowing_policy.mk`.
- Runtime SettingsProvider defaults live in `overlays/SettingsProvider`.
- Boot-time reinforcement lives in Cuttlefish `set_adb.sh`, represented by
  `patches/device-google-cuttlefish.patch`.
- Launcher desktop taskbar guards live in
  `patches/packages-apps-Launcher3.patch`.
- Framework/Shell desktop-first behavior lives in `patches/frameworks-base.patch`.

When adding a new desktop behavior, prefer the narrowest layer:

1. Overlay resource, if the platform already exposes one.
2. Product makefile property, if the behavior is product policy.
3. Boot-time setting, if user data can drift after first boot.
4. Source patch, only when no overlay/property hook exists.
