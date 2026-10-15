[README](README.md) | **UI Intro** | [Ika commands](USAGE.md) | [Changelog](CHANGELOG.md) | [Downloads](DOWNLOADS.md)

# UI Intro

## Window Handling

The clock at the top left of the console window is also a **hot corner**.
Click and hold it to move the console window. If the window is maximized or
fullscreen, click it once to return to windowed mode.

Drag the window to the left or right edge of the screen to fill half
of the desktop, or drag it to the top edge to maximize the window.

Super (Command) + F switches fullscreen mode on and off.

Super (Command) + T switches the title bar on and off.

Without a title bar, resize the console by dragging just outside its edges:
the window keeps an invisible 4-pixel margin for that, so the edge of the
Android desktop stays clickable. While a window is resized, its last complete
picture is stretched and blurred until Android has drawn the new size.

## App windows

With the VM running, `ika app PACKAGE` opens a single app in its own
resizable window with a normal title bar, separate from the desktop console.
Each window is backed by a Cuttlefish display of its own, added while the VM
runs and removed when the window closes, and shown with raw frames like the
console. The app is drawn at the window size, so resizing the window gives
the app more room rather than stretching it. Super + T and Super + F work as they do in the console.

- The app is restarted on the new display if it was already running on the
  desktop, and closing the window closes the app.
- Apps can be named by package or by the label shown by `ika app`.
  Labels match case-insensitively, exactly or by a unique part
  (`ika app setti` opens Settings), and need no quotes when they contain
  spaces. An ambiguous name lists the matching apps instead of guessing.
- Some apps are hidden from `ika app`, name matching and the menu: Android
  Switch, the Google search app, Calculator, Calendar, Clock, Contacts,
  Recorder and AudioFX. See `IKA_HIDDEN_APPS` in `tools/ika`. They
  still open when given by full package name.
- The window title is the app's label; override it with `--title=TEXT`. Window
  size is remembered per app under `~/ika/apps/PACKAGE/`; `--size=WxH` sets
  it explicitly.
- `--game` enables UHID gamepad, keyboard and mouse input without forcing
  fullscreen; add `-f` for fullscreen.
- **Games** (apps that declare `android:appCategory="game"`, or are listed in
  `IKA_GAME_APPS` in `tools/ika`) start in a **game session** instead of an
  app window: the console switches to fullscreen game mode (gamepad, keyboard
  and mouse passthrough, raw frames rather than encoded video) and the game
  runs fullscreen on Android's primary display. Leaving fullscreen or closing
  that window ends the session: the window closes, and the game is sent to
  the background (Home, where it saves its state), so the Android desktop is
  in front the next time you open Ika; starting the game again resumes it
  where you left it. The desktop console comes back if it was open before.
  As on a phone, Android may still reclaim a backgrounded game, which then
  starts fresh. Starting another game replaces the current one.
  `ika app NAME --window` opens a game in its own window instead. Only games
  started with `ika app` (or from the menu) behave this way; `ika start --game`
  and games opened inside the Android desktop are unaffected.
- **Touch input** (`ika app NAME --touch`) is for games that ignore the mouse.
  Left-button clicks and drags are sent to Android as a real finger on a
  touchscreen instead of as mouse input, so a drag is a swipe. The right and
  middle buttons and the wheel stay mouse input, Ctrl or Shift with the left
  button still simulates a pinch, and no hover is sent. In a game session the
  mouse leaves UHID (the gamepad and keyboard still pass through as HID
  devices), and a session already running in the other input mode is
  restarted when you start a game in the new one. `--touch` works with app
  windows too, and `IKA_TOUCH=1 ika start --game` does the same for the
  console. Most desktop apps should not use it: some route mouse clicks
  differently from touch, for example Chromium's tab strip.
- `ika app sync` adds every launchable app to the desktop's app menu, as
  "🎮 ∙ LABEL" for games (apps declaring `android:appCategory="game"`, or listed
  in `IKA_GAME_APPS` in `tools/ika`) and "ᗩ ∙ LABEL" for other apps, in an
  "Android Apps (Ika)" group: a folder in the GNOME app
  grid, or a submenu on KDE Plasma, XFCE, Cinnamon and MATE. Launchers are
  `~/.local/share/applications/ika-PACKAGE.desktop` and are named after the
  app window's ID, so the dock and task switcher show an open app window
  under its launcher. Each launcher gets the app's own icon, rendered by
  Android so adaptive icons look as they do in the Ika launcher, and stored
  in `~/ika/apps/icons/`. Edits you make to a launcher are kept unless the
  app's label or icon changes.
- Menu entries work while Ika is stopped: `ika app` then starts the VM
  without the desktop console (`ika start --no-console`) and opens the app
  once Android has booted. Launched from a menu, `ika app` reports progress
  and errors as desktop notifications.
- Right-click a menu entry for **App Settings**, which opens the app's
  Android App info page (permissions, storage, force stop, uninstall) in the
  Settings window. From a terminal: `ika app --info NAME`. The entries of
  games also offer **Play with Touch Input**, which runs
  `ika app --touch PACKAGE`.
- The menu is kept up to date automatically: once the guest has booted,
  `ika start` runs a background watcher that syncs the menu and then checks
  every few seconds (`IKA_APP_MENU_POLL_SEC`, default 5) for installed,
  updated, removed, enabled or disabled apps. It logs to `~/ika/app-menu.log`
  and stops with the VM. `ika app sync` forces a sync. `ika app sync --remove`
  deletes the launchers and the group and turns the automatic sync off until
  `ika app sync` is run again. `ika reset` removes the entries too, since a
  factory reset removes the apps; the next `ika start` rebuilds the menu.
- `ika start` leaves app windows open; `ika stop`, `reset` and `restart` close
  them.
