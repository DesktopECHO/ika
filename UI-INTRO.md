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

## TV mode

In Android's TV mode the console is the TV screen: it always opens
fullscreen, as every app inside it does, the interface is 1.5 times its
desktop size, a right click goes Back (Shift + right click for a right click)
and the gamepad is the remote. Android apps opened from the Linux desktop's
app menu or with `ika app` still open in their own windows.
See [TV mode compared with desktop mode](USAGE.md#tv-mode-compared-with-desktop-mode)
for every difference, and [TV mode](USAGE.md#tv-mode) for switching.

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
- **Games** (apps that declare `android:appCategory="game"`, or are listed in
  `IKA_GAME_APPS` in `tools/ika`) open in their own windows like any other
  app. They are marked as games in the app menu, and a game added to the
  menu starts with **Fullscreen mode** ticked in its start options (below),
  so its window opens fullscreen.
- **Touch input** (`ika app NAME --touch`) is for games that ignore the mouse.
  Left-button clicks and drags are sent to Android as a real finger on a
  touchscreen instead of as mouse input, so a drag is a swipe. The right and
  middle buttons and the wheel stay mouse input, Ctrl or Shift with the left
  button still simulates a pinch, and no hover is sent. It wins over passing
  the mouse through (the keyboard and gamepads still pass through as HID
  devices when ticked). Most desktop apps should not use it: some route mouse
  clicks differently from touch, for example Chromium's tab strip.
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
- Right-click a menu entry for **Android App Settings...**, which opens the
  app's Android App info page (permissions, storage, force stop, uninstall)
  in the Settings window. From a terminal: `ika app --info NAME`.
- Right-click a menu entry for **Ika Startup Options...** to choose how that
  app starts, in a window with a checkbox for each option: **Fullscreen mode**;
  the keyboard, the mouse and gamepads each passed through to Android as a
  HID device; **Use the keyboard to emulate a gamepad**
  (WASD, the arrows, Space, Esc, ...; see
  [App input](USAGE.md#app-input)); and **Touch input**. Without them an
  app or game gets the desktop's keyboard and mouse and no gamepad. A game
  added to the menu starts with **Fullscreen mode** ticked. **Apply settings**
  saves the ticked options in `~/ika/app-options.ini`, **Apply and start**
  saves them and starts the app with them, and **Cancel** leaves them as
  they were. They
  apply every time the app starts, from the menu or with `ika app NAME`;
  options typed after `ika app NAME` are added to them. From a terminal:
  `ika app --options NAME`. yad draws the window, in the desktop's light or
  dark style.
- Right-click a game's menu entry for **Controller mapping...**, a window
  with the keyboard gamepad's keys and settings for that game: the keys of
  each control, the mouse's buttons and wheel among them, how fast a stick
  is pushed, how far it goes with the walk key held, what opposite keys do
  together, and which stick the mouse moves and how fast. **Apply settings** saves
  them for the game, over `ika.ini`, and ticks **Use the keyboard as a
  gamepad** in its start options; **Apply and start** also starts it;
  **Reset to ika.ini** forgets the game's mapping (see
  [Controller mapping per game](USAGE.md#controller-mapping-per-game)).
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
