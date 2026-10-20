#!/usr/bin/env bash
#
# Take a full-screen screenshot of a GNOME Wayland desktop from an ssh
# session and save it locally.
#
#   gnome-screenshot-ssh.sh [user@]host [output.png]
#   gnome-screenshot-ssh.sh --local [output.png]      # run on the host itself
#
# The output defaults to <host>-<timestamp>.png in the current directory;
# "-" writes the PNG to stdout.  Extra ssh options go in $SSH_OPTS.
#
# GNOME refuses org.gnome.Shell.Screenshot for callers that are not on its
# allow list, and gnome-screenshot itself fails on GNOME 50, so this goes
# through the desktop portal instead: org.freedesktop.portal.Screenshot
# accepts any client on the session bus.  A non-interactive request only
# succeeds without a dialog on the host's screen when the permission store
# says "yes" for the screenshot permission of unsandboxed apps, so the
# script records that first (table "screenshot", id "screenshot", app "").
# Nothing has to run inside the desktop session: the portal only needs the
# session bus, which lives at /run/user/<uid>/bus.
#
# Needs python3 with GObject introspection (python3-gobject) and a running
# xdg-desktop-portal with a backend that implements Screenshot
# (xdg-desktop-portal-gnome) on the host; both come with GNOME.

set -u

usage() {
  echo "usage: ${0##*/} [user@]host [output.png | -]" >&2
  echo "       ${0##*/} --local [output.png | -]" >&2
  exit 2
}

# Runs on the host.  Writes the PNG to stdout, messages to stderr.
read -r -d '' REMOTE_PY <<'EOF'
import os, sys, time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

TIMEOUT = 30  # seconds to wait for the portal's response

def die(msg, code=1):
    print("gnome-screenshot-ssh: " + msg, file=sys.stderr)
    sys.exit(code)

os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS",
                      "unix:path=/run/user/%d/bus" % os.getuid())
try:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
except GLib.Error as e:
    die("no session bus at %s: %s" % (os.environ["DBUS_SESSION_BUS_ADDRESS"], e.message))

PORTAL = "org.freedesktop.portal.Desktop"
STORE = "org.freedesktop.impl.portal.PermissionStore"

def call(dest, path, iface, method, args, reply, timeout=5000):
    return bus.call_sync(dest, path, iface, method, args,
                         GLib.VariantType(reply) if reply else None,
                         Gio.DBusCallFlags.NONE, timeout, None)

# Allow non-interactive screenshots for unsandboxed apps, so the portal does
# not put a permission dialog on the host's screen and wait for a click.
try:
    perms, _ = call(STORE, "/org/freedesktop/impl/portal/PermissionStore", STORE,
                    "Lookup", GLib.Variant("(ss)", ("screenshot", "screenshot")),
                    "(a{sas}v)").unpack()
except GLib.Error as e:
    if "NotFound" not in e.message:
        die("permission store lookup failed: " + e.message)
    perms = {}
if perms.get("", []) != ["yes"]:
    try:
        call(STORE, "/org/freedesktop/impl/portal/PermissionStore", STORE,
             "SetPermission",
             GLib.Variant("(sbssas)", ("screenshot", True, "screenshot", "", ["yes"])),
             None)
    except GLib.Error as e:
        die("could not grant the screenshot permission: " + e.message)
    print("gnome-screenshot-ssh: granted non-interactive screenshots to host apps",
          file=sys.stderr)

# The portal answers on a Request object whose path is derived from our
# unique bus name and the token we pass; subscribe before calling.
token = "shot%d%d" % (os.getpid(), int(time.time()))
sender = bus.get_unique_name()[1:].replace(".", "_")
req_path = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)
loop = GLib.MainLoop()
result = {}

def on_response(conn, s, path, iface, signal, params):
    result["code"], result["res"] = params.unpack()
    loop.quit()

bus.signal_subscribe(PORTAL, "org.freedesktop.portal.Request", "Response", req_path,
                     None, Gio.DBusSignalFlags.NO_MATCH_RULE, on_response)
try:
    handle, = call(PORTAL, "/org/freedesktop/portal/desktop",
                   "org.freedesktop.portal.Screenshot", "Screenshot",
                   GLib.Variant("(sa{sv})", ("", {
                       "handle_token": GLib.Variant("s", token),
                       "interactive": GLib.Variant("b", False),
                       "modal": GLib.Variant("b", False)})),
                   "(o)", TIMEOUT * 1000).unpack()
except GLib.Error as e:
    die("the screenshot portal refused: " + e.message)
if handle != req_path:
    # Old portals pick their own path; listen there too.
    bus.signal_subscribe(PORTAL, "org.freedesktop.portal.Request", "Response", handle,
                         None, Gio.DBusSignalFlags.NO_MATCH_RULE, on_response)
GLib.timeout_add_seconds(TIMEOUT, loop.quit)
loop.run()

if "code" not in result:
    die("no answer from the portal within %ds (a dialog may be waiting on the host's screen)" % TIMEOUT)
if result["code"] != 0:
    die("the portal did not take a screenshot (response %d: %s)" % (result["code"], result["res"]))
uri = result["res"].get("uri", "")
if not uri.startswith("file://"):
    die("unexpected screenshot location: " + repr(uri))
path = GLib.filename_from_uri(uri)[0]
try:
    with open(path, "rb") as f:
        data = f.read()
    os.unlink(path)
except OSError as e:
    die("cannot read the screenshot %s: %s" % (path, e))
sys.stdout.buffer.write(data)
sys.stdout.buffer.flush()
EOF

[ $# -ge 1 ] || usage
host=$1
shift
case $host in
  -h|--help) usage ;;
esac
[ $# -le 1 ] || usage

if [ "$host" = --local ]; then
  label=$(hostname -s 2>/dev/null || echo local)
  run() { python3 -I - ; }
else
  label=${host#*@}
  run() { ssh ${SSH_OPTS:-} "$host" python3 -I - ; }
fi

out=${1:-$label-$(date +%Y%m%d-%H%M%S).png}
tmp=$(mktemp "${TMPDIR:-/tmp}/gnome-shot.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT

run <<<"$REMOTE_PY" >"$tmp"
rc=$?
if [ $rc -ne 0 ]; then
  echo "${0##*/}: failed on $label (exit $rc)" >&2
  exit $rc
fi
if [ "$(head -c 8 "$tmp" | od -An -tx1 | tr -d ' \n')" != 89504e470d0a1a0a ]; then
  echo "${0##*/}: $label did not return a PNG" >&2
  head -c 300 "$tmp" >&2
  exit 1
fi

if [ "$out" = - ]; then
  cat "$tmp"
else
  cat "$tmp" >"$out" || exit 1   # not mv: the file should get the umask, not mktemp's 0600
  echo "$out"
fi
