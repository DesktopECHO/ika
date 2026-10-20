#!/usr/bin/bash

# The console window follows the session: SDL's video driver is wayland on a
# Wayland session, x11 on an X11 one, and a driver set in the environment wins.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"
unset WAYLAND_DISPLAY DISPLAY SDL_VIDEO_DRIVER SDL_VIDEODRIVER GTK_THEME

source "${ROOT}/tools/ika"
host_color_scheme() { printf 'light\n'; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Prints the SDL video driver variables of the scrcpy environment.
sdl_driver() {
  local -a env_vars=()
  append_scrcpy_env env_vars
  printf '%s\n' "${env_vars[@]}" | grep '^SDL_VIDEO' | tr '\n' ' '
}

[[ "$(sdl_driver)" == "" ]] || fail "no session: $(sdl_driver)"
[[ "$(WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 sdl_driver)" == "SDL_VIDEO_DRIVER=wayland SDL_VIDEODRIVER=wayland " ]] \
  || fail "Wayland session with Xwayland: $(WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 sdl_driver)"
[[ "$(WAYLAND_DISPLAY=wayland-0 sdl_driver)" == "SDL_VIDEO_DRIVER=wayland SDL_VIDEODRIVER=wayland " ]] \
  || fail "Wayland session: $(WAYLAND_DISPLAY=wayland-0 sdl_driver)"
[[ "$(DISPLAY=:0 sdl_driver)" == "SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11 " ]] \
  || fail "X11 session: $(DISPLAY=:0 sdl_driver)"
[[ "$(WAYLAND_DISPLAY=wayland-0 SDL_VIDEO_DRIVER=x11 sdl_driver)" == "" ]] \
  || fail "a driver set in the environment was replaced: $(WAYLAND_DISPLAY=wayland-0 SDL_VIDEO_DRIVER=x11 sdl_driver)"
[[ "$(WAYLAND_DISPLAY=wayland-0 SDL_VIDEODRIVER=x11 sdl_driver)" == "" ]] \
  || fail "a legacy driver variable was overridden"

echo "ika console video driver tests passed"
