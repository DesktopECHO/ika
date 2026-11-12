# ika: ika's own GTK windows, and the app settings window.
# Sourced by src/tools/ika, in its order; see there.

# The program of ika's window, in Python: form fields, given as yad's --form
# takes them, in the tabs of a GTK 3 window (Gtk.Notebook), native on Wayland
# as on X11. Its arguments are described at its start; ika_window runs it.
ika_window_py() {
  cat <<'PYTHON'
import json
import sys

# Form fields, given as yad's --form takes them, in tabs of a GTK 3 window of
# its own (Gtk.Notebook), which runs natively on Wayland and X11 alike.
#
#   --title=TEXT --icon=NAME --app-id=ID --active-tab=N
#   --button=LABEL:CODE ...
#   then, per tab: --tab=NAME --output=FILE [--columns=N] [--align=right]
#   [--text=MARKUP] [--border=PX] [--compact] [--field=LABEL:TYPE VALUE]...
#
# A field's TYPE is NUM (VALUE "N!MIN..MAX!STEP"), CB ("a!^b!c", ^ the chosen
# one), CHK (TRUE or FALSE), LBL (LABEL is markup), or anything else for a
# text entry; yad splits LABEL from TYPE at the last colon. Fields fill the
# columns in turn, the first ceil(n / N) the first column. A button, or
# closing the window (252, as Escape), writes each tab's values to its
# output as yad prints them, each followed by "|", and exits with its code.
# --running-label=CODE:LABEL is button CODE's label while an app runs, as
# --running-pid=FILE:MARKER and --running-file=FILE tell: FILE holds the pid
# of a live process of this user with the argument MARKER, or FILE is there.
# The window looks again every half second, and the button is as wide as the
# longer of its two labels.
# --undecorated leaves the window without a title bar, as the confirmation is.
# --yellow-choice=TEXT shows the CB choice TEXT in yellow, in every CB.
# --same-width=LABEL!LABEL... makes the fields of those labels (spaces around
# each aside) as wide as each other, the widest of them; each --same-width is
# a group of its own.
# --parse-only prints what was parsed, as JSON, --print-labels the buttons'
# labels as the window would show them now, one a line, and --print-defaults
# writes the outputs as the window would show them, then exits with
# --test-status=CODE: none needs a display.


def parse(argv):
    window = {"title": "", "icon": "", "app_id": "", "active_tab": 1,
              "buttons": [], "tabs": [], "mode": "", "test_status": 0,
              "running_labels": {}, "running_pids": [], "running_files": [],
              "yellow_choices": [], "same_width": [], "undecorated": False}
    tab = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        name, _, value = arg.partition("=")
        if name == "--field":
            if tab is None:
                raise SystemExit("ika window: --field before --tab")
            label, colon, ftype = value.rpartition(":")
            if not colon:
                label, ftype = value, ""
            field_value = argv[i + 1] if i + 1 < len(argv) else ""
            tab["fields"].append({"label": label, "type": ftype, "value": field_value})
            i += 2
            continue
        i += 1
        if name == "--tab":
            tab = {"name": value, "output": "", "columns": 1, "align": "left",
                   "text": "", "border": 0, "compact": False, "fields": []}
            window["tabs"].append(tab)
        elif tab is not None and name in ("--output", "--align", "--text"):
            tab[name[2:]] = value
        elif tab is not None and name in ("--columns", "--border"):
            tab[name[2:]] = max(int(value or 0), 1 if name == "--columns" else 0)
        elif tab is not None and name == "--compact":
            tab["compact"] = True
        elif name == "--button":
            label, _, code = value.rpartition(":")
            window["buttons"].append({"label": label.strip(), "code": int(code)})
        elif name == "--running-label":
            code, _, label = value.partition(":")
            window["running_labels"][int(code)] = label.strip()
        elif name == "--running-pid":
            path, _, marker = value.rpartition(":")
            window["running_pids"].append([path, marker])
        elif name == "--running-file":
            window["running_files"].append(value)
        elif name == "--undecorated":
            window["undecorated"] = True
        elif name == "--yellow-choice":
            window["yellow_choices"].append(value)
        elif name == "--same-width":
            window["same_width"].append([item.strip() for item in value.split("!")])
        elif name == "--active-tab":
            window["active_tab"] = int(value or 1)
        elif name == "--test-status":
            window["test_status"] = int(value or 0)
        elif name in ("--title", "--icon", "--app-id"):
            window[name[2:].replace("-", "_")] = value
        elif name in ("--parse-only", "--print-defaults", "--print-labels"):
            window["mode"] = name[2:]
        else:
            raise SystemExit("ika window: unknown argument " + arg)
    return window


def number_spec(value):
    """N!MIN..MAX!STEP as numbers, yad's defaults where missing."""
    parts = value.split("!")
    number = float(parts[0] or 0)
    low, high, step = 0.0, 65535.0, 1.0
    if len(parts) > 1 and ".." in parts[1]:
        low_text, _, high_text = parts[1].partition("..")
        low, high = float(low_text or 0), float(high_text or 0)
    if len(parts) > 2 and parts[2]:
        step = float(parts[2])
    return number, low, high, step


def choices(value):
    """The choices of CB's VALUE, and the index of the one marked with ^."""
    items = []
    active = 0
    for item in value.split("!"):
        if item.startswith("^"):
            active = len(items)
            item = item[1:]
        items.append(item)
    return items, active


def default_value(field):
    """What the window shows for FIELD before it is changed, as yad prints it."""
    ftype = field["type"]
    if ftype == "LBL":
        return ""
    if ftype == "NUM":
        return str(int(number_spec(field["value"])[0]))
    if ftype == "CB":
        items, active = choices(field["value"])
        return items[active] if items else ""
    if ftype == "CHK":
        return "TRUE" if field["value"].upper() == "TRUE" else "FALSE"
    return field["value"]


def app_running(window):
    """Whether the app of --running-pid and --running-file runs"""
    import os
    for path, marker in window["running_pids"]:
        try:
            with open(path, encoding="utf-8") as pid_file:
                pid = pid_file.read().strip()
            if not pid.isdigit() or os.stat("/proc/" + pid).st_uid != os.getuid():
                continue
            with open("/proc/%s/cmdline" % pid, "rb") as cmdline:
                if marker.encode() in cmdline.read().split(b"\0"):
                    return True
        except OSError:
            continue
    return any(os.path.exists(path) for path in window["running_files"])


def button_label(window, button, running):
    if running:
        return window["running_labels"].get(button["code"], button["label"])
    return button["label"]


def write_outputs(window, values):
    for tab, tab_values in zip(window["tabs"], values):
        if tab["output"]:
            with open(tab["output"], "w", encoding="utf-8") as output:
                output.write("".join(value + "|" for value in tab_values) + "\n")


CSS = b"""
.ika-compact { font-size: 85%; }
.ika-compact entry, .ika-compact spinbutton, .ika-compact combobox button {
  min-height: 20px; padding-top: 1px; padding-bottom: 1px; }
.ika-compact spinbutton button { min-height: 0; padding-top: 0; padding-bottom: 0; }
combobox button arrow { margin-left: 10px; }
"""


# On WSLg (IKA_WINDOWS_SCALE, Windows' display scale in percent), the title bar
# looks and behaves like Windows 11's, as scrcpy's title bars do on WSLg
# (scrcpy/app/src/ika/window.c, sc_ika_window_init_caption, whose metrics,
# glyphs and CSS these mirror: a change to one goes to the other): its height,
# its three buttons with their glyphs and their hover, the title in Segoe UI
# Variable, faded with the buttons while the window is inactive. Where an app
# window's title bar takes the color of the top of the app, this one has the
# window's own background. The glyphs are symbolic icons in scrcpy's glyph
# directory, written when missing.
CAPTION_HEIGHT = 32
CAPTION_BUTTON_WIDTH = 46
CAPTION_GLYPH = 10
CAPTION_FONT_SIZE = 12
CAPTION_TITLE_PADDING = 12
CAPTION_RADIUS = 8


def caption_ring(x, y, w, h, r, t):
    """The path of a rounded rectangle outline T thick (even-odd)"""
    path = ""
    for _ in range(2):
        rr = min(max(r, 0), w / 2, h / 2)
        path += ("M%.3f %.3fh%.3fa%.3f %.3f 0 0 1 %.3f %.3fv%.3f"
                 "a%.3f %.3f 0 0 1 %.3f %.3fh%.3fa%.3f %.3f 0 0 1 %.3f %.3f"
                 "v%.3fa%.3f %.3f 0 0 1 %.3f %.3fz") % (
                     x + rr, y, w - 2 * rr, rr, rr, rr, rr, h - 2 * rr,
                     rr, rr, -rr, rr, -(w - 2 * rr), rr, rr, -rr, -rr,
                     -(h - 2 * rr), rr, rr, rr, -rr)
        x += t
        y += t
        w -= 2 * t
        h -= 2 * t
        r -= t
    return path


def caption_glyphs(g):
    """The SVGs of the caption glyphs, G x G pixels, by name"""
    r = max(1, g * 0.15)
    front = int(g * 0.8 + 0.5)
    off = g - front
    d = 0.70710678  # half the width of a 1-pixel diagonal, projected
    back = caption_ring(off, 0, front, front, r * 0.8, 1)
    shapes = {
        # A whole pixel row, so that the line stays sharp
        "minimize": ("", "M0 %dh%dv1H0z" % (g // 2, g)),
        "maximize": ("", caption_ring(0, 0, g, g, r, 1)),
        # The front window bottom left, the back one's outline clipped where
        # the front one covers it (and a pixel apart)
        "restore": (
            '<clipPath id="c"><path clip-rule="evenodd" '
            'd="M0 0H%dV%dH0zM0 %dH%dV%dH0z"/></clipPath>'
            '<path fill="#000" fill-rule="evenodd" clip-path="url(#c)" d="%s"/>'
            % (g, g, g - front - 1, front + 1, g, back),
            caption_ring(0, off, front, front, r * 0.8, 1)),
        "close": ("", "M0 %.3fL%.3f 0L%d %.3fL%.3f %dzM%.3f 0L%d %.3fL%.3f %dL0 %.3fz"
                  % (d, d, g, g - d, g - d, g, g - d, g, d, d, g, g - d)),
    }
    return {
        name: '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
              'viewBox="0 0 %d %d">%s<path fill="#000" fill-rule="evenodd" '
              'd="%s"/></svg>\n' % (g, g, g, g, clipped, path)
        for name, (clipped, path) in shapes.items()
    }


def caption_glyph_dir(g):
    """scrcpy's directory for the glyphs of size G, created"""
    import os
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    base = (os.path.join(runtime, "ika-caption") if runtime
            else "/tmp/ika-caption-%d" % os.getuid())
    path = os.path.join(base, "%dpx" % g)
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def wslg_caption(Gtk, Gdk):
    import os
    try:
        pct = int(os.environ.get("IKA_WINDOWS_SCALE", ""))
    except ValueError:
        return
    if not 100 <= pct <= 500:
        pct = 100

    def px(v):
        return int(v * pct / 100 + 0.5)

    glyph = px(CAPTION_GLYPH)
    try:
        directory = caption_glyph_dir(glyph)
        for name, svg in caption_glyphs(glyph).items():
            path = os.path.join(directory, "ika-caption-%s-symbolic.svg" % name)
            if not os.path.exists(path):
                tmp = "%s.tmp.%d" % (path, os.getpid())
                with open(tmp, "w") as f:
                    f.write(svg)
                os.replace(tmp, path)
    except OSError:
        return
    Gtk.IconTheme.get_default().append_search_path(directory)
    # Windows windows have the three buttons (GNOME's default, without
    # Ubuntu's desktop settings, is the close button only)
    Gtk.Settings.get_default().set_property("gtk-decoration-layout", ":minimize,maximize,close")

    css = """
headerbar.default-decoration {
 min-height: %(height)dpx; padding: 0 0 0 %(padding)dpx; margin: 0;
 border-radius: %(radius)dpx %(radius)dpx 0 0;
 font-family: "Segoe UI Variable Text", "Segoe UI Variable", "Segoe UI", sans-serif;
 font-size: %(font)dpx; }
window.maximized headerbar.default-decoration { border-radius: 0; }
headerbar.default-decoration .title { font-weight: normal; font-size: %(font)dpx; }
headerbar.default-decoration:backdrop .title,
 headerbar.default-decoration:backdrop button.titlebutton { opacity: 0.55; }
headerbar.default-decoration button.titlebutton {
 min-width: %(button)dpx; min-height: %(height)dpx; padding: 0;
 margin: 0 -3px;
 border: none; border-radius: 0; box-shadow: none; outline: none;
 background-color: transparent; background-repeat: no-repeat;
 background-position: center; background-size: %(glyph)dpx %(glyph)dpx; }
headerbar.default-decoration button.titlebutton image { -gtk-icon-transform: scale(0.01); }
headerbar.default-decoration button.titlebutton.minimize {
 background-image: -gtk-icontheme("ika-caption-minimize-symbolic"); }
headerbar.default-decoration button.titlebutton.maximize {
 background-image: -gtk-icontheme("ika-caption-maximize-symbolic"); }
window.maximized headerbar.default-decoration button.titlebutton.maximize {
 background-image: -gtk-icontheme("ika-caption-restore-symbolic"); }
headerbar.default-decoration button.titlebutton.close {
 background-image: -gtk-icontheme("ika-caption-close-symbolic");
 margin-right: 0; border-radius: 0 %(radius)dpx 0 0; }
window.maximized headerbar.default-decoration button.titlebutton.close { border-radius: 0; }
headerbar.default-decoration button.titlebutton:hover { background-color: alpha(currentColor, 0.06); }
headerbar.default-decoration button.titlebutton:active { background-color: alpha(currentColor, 0.04); }
headerbar.default-decoration button.titlebutton.close:hover { background-color: #c42b1c; color: #ffffff; }
headerbar.default-decoration button.titlebutton.close:active {
 background-color: rgba(196, 43, 28, 0.9); color: #ffffff; }
headerbar.default-decoration, headerbar.default-decoration:backdrop {
 background: @theme_bg_color; background-image: none;
 border-color: @theme_bg_color; box-shadow: none; }
headerbar.default-decoration .title, headerbar.default-decoration:backdrop .title,
 headerbar.default-decoration button, headerbar.default-decoration:backdrop button {
 color: @theme_fg_color; }
""" % {
        "height": px(CAPTION_HEIGHT), "padding": px(CAPTION_TITLE_PADDING),
        "radius": px(CAPTION_RADIUS), "font": px(CAPTION_FONT_SIZE),
        "button": px(CAPTION_BUTTON_WIDTH), "glyph": glyph,
    }
    provider = Gtk.CssProvider()
    provider.load_from_data(css.encode())
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)


def yellow_choices(combo, yellow, Gdk, Gtk):
    """Shows COMBO's choices in YELLOW in yellow, in the list and when chosen,
    a shade that reads on light and dark themes alike; the row the list
    highlights keeps the theme's color, which reads on the highlight."""
    cell = combo.get_cells()[0]
    color = Gdk.RGBA()
    color.parse("#a98000")
    highlighted = [None]

    def paint(layout, cell, model, row, data):
        if (model.get_value(row, 0) in yellow
                and model.get_path(row).get_indices()[0] != highlighted[0]):
            cell.set_property("foreground-rgba", color)
        else:
            cell.set_property("foreground-set", False)

    def highlight(item, index):
        highlighted[0] = index
        item.queue_draw()

    # The list is a menu of the rows, made when it first opens
    def popup_shown(combo, _):
        menu = combo.get_popup_accessible().get_widget()
        if not combo.get_property("popup-shown") or not isinstance(menu, Gtk.Menu):
            return
        for index, item in enumerate(menu.get_children()):
            if not getattr(item, "ika_yellow", False):
                item.ika_yellow = True
                item.connect("select", highlight, index)
                item.connect("deselect", highlight, None)

    combo.set_cell_data_func(cell, paint, None)
    combo.connect("notify::popup-shown", popup_shown)


def run(window):
    from gi.repository import GLib
    if window["app_id"]:
        # The app ID on Wayland, the class on X11: the desktop entry of that
        # name gives the window its icon in the dock and the task bar
        GLib.set_prgname(window["app_id"])
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, Gtk
    if window["app_id"]:
        Gdk.set_program_class(window["app_id"])

    import os
    for css in (CSS, os.environ.get("IKA_WINDOW_CSS", "")):
        if css:
            provider = Gtk.CssProvider()
            provider.load_from_data(css.encode() if isinstance(css, str) else css)
            Gtk.StyleContext.add_provider_for_screen(
                Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    wslg_caption(Gtk, Gdk)

    readers = []
    result = {"code": 252}

    def finish(code):
        write_outputs(window, [[read() for read in tab_readers] for tab_readers in readers])
        result["code"] = code
        Gtk.main_quit()

    gtk_window = Gtk.Window(title=window["title"])
    if window["icon"]:
        gtk_window.set_icon_name(window["icon"])
        Gtk.Window.set_default_icon_name(window["icon"])
    gtk_window.set_position(Gtk.WindowPosition.CENTER)
    if window["undecorated"]:
        gtk_window.set_decorated(False)
    gtk_window.connect("delete-event", lambda *_: finish(252) or True)
    gtk_window.connect(
        "key-press-event",
        lambda _, event: (finish(252) or True) if event.keyval == Gdk.KEY_Escape else False)

    same_width = [Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL)
                  for _ in window["same_width"]]
    notebook = Gtk.Notebook()
    if len(window["tabs"]) < 2:
        notebook.set_show_tabs(False)
        notebook.set_show_border(False)
    for tab in window["tabs"]:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        page.set_border_width(tab["border"])
        if tab["compact"]:
            page.get_style_context().add_class("ika-compact")
        if tab["text"]:
            text = Gtk.Label()
            text.set_markup(tab["text"])
            text.set_justify(Gtk.Justification.CENTER)
            page.pack_start(text, False, False, 0)
        fields = tab["fields"]
        columns = tab["columns"]
        rows = -(-len(fields) // columns) if fields else 0
        stretch = columns > 1
        # Several columns are a grid, as yad's; one is rows of their own, a
        # label and its field beside it, the labels as wide as the widest,
        # so that a checkbox or a label across the row widens no column
        row_spacing = 3 if tab["compact"] else 5
        grid = Gtk.Grid(row_spacing=row_spacing, column_spacing=8)
        rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=row_spacing)
        captions = Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL)
        page.pack_start(grid if stretch else rows_box, False, False, 0)

        def place(widget, row, x, width, caption=None):
            if stretch:
                if caption is not None:
                    grid.attach(caption, x, row, 1, 1)
                    grid.attach(widget, x + 1, row, 1, 1)
                else:
                    grid.attach(widget, x, row, width, 1)
            elif caption is not None:
                line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
                captions.add_widget(caption)
                line.pack_start(caption, False, False, 0)
                line.pack_start(widget, widget.get_hexpand(), widget.get_hexpand(), 0)
                rows_box.pack_start(line, False, False, 0)
            else:
                rows_box.pack_start(widget, False, False, 0)

        tab_readers = []
        for index, field in enumerate(fields):
            row, column = index % rows, index // rows
            x = column * 2
            label, ftype, value = field["label"], field["type"], field["value"]
            if ftype == "LBL":
                widget = Gtk.Label()
                widget.set_markup(label)
                widget.set_xalign(0)
                place(widget, row, x, 2)
                tab_readers.append(lambda: "")
                continue
            if ftype == "CHK":
                widget = Gtk.CheckButton(label=label)
                widget.set_active(value.upper() == "TRUE")
                place(widget, row, x, 2)
                tab_readers.append(lambda w=widget: "TRUE" if w.get_active() else "FALSE")
                continue
            caption = Gtk.Label(label=label)
            caption.set_xalign(1 if tab["align"] == "right" else 0)
            if ftype == "NUM":
                number, low, high, step = number_spec(value)
                widget = Gtk.SpinButton.new_with_range(low, high, step)
                widget.set_digits(0)
                widget.set_value(number)
                widget.set_width_chars(max(len(str(int(high))), 3))
                tab_readers.append(lambda w=widget: str(w.get_value_as_int()))
            elif ftype == "CB":
                items, active = choices(value)
                widget = Gtk.ComboBoxText()
                for item in items:
                    widget.append_text(item)
                if set(items) & set(window["yellow_choices"]):
                    yellow_choices(widget, window["yellow_choices"], Gdk, Gtk)
                widget.set_active(active)
                tab_readers.append(lambda w=widget: w.get_active_text() or "")
            else:
                widget = Gtk.Entry()
                widget.set_text(value)
                widget.set_width_chars(18)
                widget.set_activates_default(True)
                tab_readers.append(lambda w=widget: w.get_text())
            for group, labels in zip(same_width, window["same_width"]):
                if label.strip() in labels:
                    group.add_widget(widget)
            if stretch or ftype not in ("NUM", "CB"):
                widget.set_hexpand(True)
            else:
                widget.set_halign(Gtk.Align.START)
            # The second column's labels a little apart from the first's fields
            if column:
                caption.set_margin_start(24)
            place(widget, row, x, 1, caption)
        readers.append(tab_readers)
        notebook.append_page(page, Gtk.Label(label=tab["name"]))

    # The buttons as wide as each other, across the window's width. One with
    # a label for while the app runs has both in a stack, which is as wide as
    # the wider, and shows the one of the app's state.
    buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, homogeneous=True)
    stacks = []
    for button in window["buttons"]:
        if button["code"] in window["running_labels"]:
            widget = Gtk.Button()
            stack = Gtk.Stack()
            stack.add_named(Gtk.Label(label=button["label"]), "stopped")
            stack.add_named(Gtk.Label(label=button_label(window, button, True)), "running")
            widget.add(stack)
            stacks.append(stack)
        else:
            widget = Gtk.Button(label=button["label"])
        widget.connect("clicked", lambda _, code=button["code"]: finish(code))
        buttons.pack_start(widget, True, True, 0)

    def show_app_state():
        state = "running" if app_running(window) else "stopped"
        for stack in stacks:
            stack.set_visible_child_name(state)
        return True

    content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    content.set_border_width(12)
    content.pack_start(notebook, True, True, 0)
    content.pack_start(buttons, False, False, 0)
    gtk_window.add(content)
    gtk_window.show_all()
    notebook.set_current_page(max(window["active_tab"], 1) - 1)
    if stacks:
        show_app_state()
        GLib.timeout_add(500, show_app_state)
    Gtk.main()
    return result["code"]


def main(argv):
    window = parse(argv)
    if window["mode"] == "parse-only":
        print(json.dumps(window, indent=1, ensure_ascii=False))
        return 0
    if window["mode"] == "print-labels":
        running = app_running(window)
        for button in window["buttons"]:
            print(button_label(window, button, running))
        return 0
    if window["mode"] == "print-defaults":
        write_outputs(window, [[default_value(field) for field in tab["fields"]]
                               for tab in window["tabs"]])
        return window["test_status"]
    return run(window)


sys.exit(main(sys.argv[1:]))
PYTHON
}

# Whether ika's window can open: python3 with GTK 3's bindings (python3-gobject
# and gtk3 on Fedora, python3-gi and gir1.2-gtk-3.0 on Debian), which the
# packages depend on.
ika_window_available() {
  if [[ -z "${IKA_WINDOW_AVAILABLE:-}" ]]; then
    if python3 -I -c 'import gi; gi.require_version("Gtk", "3.0")' >/dev/null 2>&1; then
      IKA_WINDOW_AVAILABLE=yes
    else
      IKA_WINDOW_AVAILABLE=no
    fi
  fi
  [[ "${IKA_WINDOW_AVAILABLE}" == "yes" ]]
}

# Stops ika when its window cannot open (ika_window_available).
require_ika_window() {
  ika_window_available \
    || die "ika's windows need python3's GTK 3 bindings (python3-gobject, or python3-gi and gir1.2-gtk-3.0); install them"
}

# Runs ika's window (ika_window_py) with the environment of the array named
# ENV_VAR and the arguments that follow; its exit status is the code of the
# button that closed it, 252 when it was closed otherwise. The program comes
# on its standard input, which keeps its command line short in ps.
ika_window() {
  local -n ika_window_env_ref="$1"
  shift
  wait_for_wslg_client
  ika_window_py | env "${ika_window_env_ref[@]}" python3 -I - "$@"
}

# On WSLg, a window made before Windows' Remote Desktop client has connected to
# WSLg's compositor (weston.log: "CreateWndow(): rdp_peer is not initalized")
# is shown once it connects, but takes no input. WSL started by the window's
# own launch, as the Startup Options from the Start menu after wsl --shutdown,
# opened it a second before the client: waits for the client's handshake in
# weston.log, which a WSL start begins anew, up to 30 seconds.
wait_for_wslg_client() {
  local weston_log="${IKA_WSLG_WESTON_LOG:-/mnt/wslg/weston.log}"
  local attempt

  [[ "${IKA_ON_WSLG}" == true && -r "${weston_log}" ]] || return 0
  for (( attempt = 0; attempt < 150; ++attempt )); do
    grep -q 'Client HandShake' "${weston_log}" 2>/dev/null && return 0
    sleep 0.2
  done
  log "WSLg's Remote Desktop client did not connect within 30 seconds; opening the window anyway"
}

# "Startup options" on a launcher (ika app --options NAME: TAB 1) and ika
# app --controller NAME (TAB 2): an app's start options and controller mapping
# in one window, "Startup Options · LABEL", with a tab for each, Startup
# Options and Gamepad Emulation, opened on TAB, the same for games and other
# apps: ika's window (ika_window), native on Wayland and X11.
#
# "Apply settings" saves the start options and the display density, and the
# mapping when it was edited or the app has one of its own: an untouched
# mapping would become the app's own copy of ika.ini's. An edited mapping
# ticks "Keyboard as a gamepad", unless the window unticked
# it. "Apply and start" also starts the app; while the app runs
# (app_is_running) it reads "Apply and restart", and closes the app first, so
# that it starts again with them. "Reset to default" asks whether
# to reset the app's start options and remove the app's mapping
# (reset_app_to_default) and, if so, shows the default start options and
# ika.ini's mapping, on the Startup Options tab. Cancel, or closing the
# window, leaves everything else as it was.
edit_app_settings() {
  local name="$1"
  local tab="${2:-1}"
  local package
  local label
  local status=0
  local option
  local dpi
  local tab_dir
  local mapping_file
  local shown_mapping
  local mapping_edited=false
  local mapping_saved=false
  local default_used=false
  local -a saved=()
  local -a options=()
  local -a kept=()
  local -a fields1=()
  local -a fields2=()
  local -a window_env=()
  local -A ticked=()
  local -A blank_at=()
  local -A keys=()
  local -A settings=()
  local -A app_settings=()

  resolve_settings_app "${name}" package label
  # One window per app: another request for it leaves the open one as it is.
  # The lock goes with this process, or before it opens the app.
  mkdir -p "${CVD_TMP_DIR}"
  exec {APP_SETTINGS_LOCK_FD}>"${CVD_TMP_DIR}/app-settings-${package}.lock"
  if ! flock -n "${APP_SETTINGS_LOCK_FD}"; then
    respond "The Startup Options of ${label} are already open"
    return 0
  fi
  require_ika_window

  read -r -a saved <<<"$(saved_app_options "${package}")"
  for option in "${saved[@]}"; do
    ticked[${option}]="true"
  done
  dpi="$(saved_app_dpi "${package}")"
  mapping_file="$(app_controller_mapping_file "${package}")"
  load_controller_mapping_form "${package}" keys settings app_settings
  shown_mapping="$(controller_mapping_form_signature keys settings)"
  set_window_env window_env
  mkdir -p "${CVD_TMP_DIR}"
  tab_dir="$(mktemp -d "${CVD_TMP_DIR}/app-settings.XXXXXX")"

  # The window is shown again after "Reset to default", on the Startup
  # Options tab, with the defaults once confirmed, else with the edits as
  # they were
  while true; do
    app_options_form_fields "${label}" "${dpi}" ticked fields1
    controller_mapping_form_fields keys settings fields2 blank_at false
    status=0
    ika_window window_env --title="Startup Options · ${label}" \
      --icon="${IKA_MENU_ICON}" --app-id="${APP_SETTINGS_WINDOW_CLASS}" \
      --active-tab="${tab}" --button="Reset to default:4" \
      --button="Apply settings:2" --button="Apply and start:0" --button="Cancel:1" \
      --running-label="0:Apply and restart" \
      --running-pid="$(app_supervisor_file "${package}" pid):__app_supervisor" \
      --running-file="$(app_background_file "${package}")" \
      --tab="Startup Options" --output="${tab_dir}/1" \
      --border="${APP_OPTIONS_TAB_BORDER_PX}" "${fields1[@]}" \
      --tab="Gamepad Emulation" --output="${tab_dir}/2" --compact --columns=2 \
      --border="${CONTROLLER_MAPPING_TAB_BORDER_PX}" --align=right \
      --text="$(controller_mapping_form_text)" "${fields2[@]}" \
      || status=$?
    case "${status}" in
      0|2|4)
        ;;
      1|252)
        rm -rf "${tab_dir}"
        if [[ "${default_used}" == "true" ]]; then
          respond "${label} has its default start options and ika.ini's controller mapping again"
        else
          respond "Start options and controller mapping of ${label} left as they were"
        fi
        return 0
        ;;
      *)
        rm -rf "${tab_dir}"
        die "could not open the start options window (it exited with ${status})"
        ;;
    esac

    read_app_options_form "$(<"${tab_dir}/1")" options dpi
    ticked=()
    for option in "${options[@]}"; do
      ticked[${option}]="true"
    done
    read_controller_mapping_form "$(<"${tab_dir}/2")" blank_at keys settings app_settings
    [[ "${status}" -eq 4 ]] || break
    tab=1
    if confirm_reset_to_default "${label}"; then
      reset_app_to_default "${package}"
      default_used=true
      read -r -a saved <<<"$(default_app_options "${package}")"
      ticked=()
      for option in "${saved[@]}"; do
        ticked[${option}]="true"
      done
      dpi=""
      load_controller_mapping_form "${package}" keys settings app_settings
      shown_mapping="$(controller_mapping_form_signature keys settings)"
    fi
  done
  rm -rf "${tab_dir}"

  if [[ "$(controller_mapping_form_signature keys settings)" != "${shown_mapping}" ]]; then
    mapping_edited=true
  fi
  if [[ "${mapping_edited}" == "true" || -e "${mapping_file}" ]]; then
    save_controller_mapping "${package}" keys settings
    mapping_saved=true
  fi
  # An edited mapping is of use with the keyboard as a gamepad, unless that
  # was unticked in the window; the options keep their usual order
  if [[ "${mapping_edited}" == "true" && " ${saved[*]} " != *" gamekb "* ]]; then
    ticked[gamekb]="true"
  fi
  kept=()
  for option in "${APP_START_OPTIONS[@]}"; do
    [[ -z "${ticked[${option}]:-}" ]] || kept+=("${option}")
  done
  save_app_options_form "${package}" "${label}" "${dpi}" "${kept[@]}"
  if [[ "${mapping_saved}" == "true" ]]; then
    respond "Controller mapping of ${label} saved"
  elif [[ "${default_used}" == "true" ]]; then
    respond "${label} uses the controller mapping of ika.ini again"
  fi
  if [[ "${status}" -eq 0 ]]; then
    start_app_with_options "${package}"
  fi
}

