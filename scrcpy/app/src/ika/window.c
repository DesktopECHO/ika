#include "window.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "util/log.h"

// At display content scale 1, scaled on HiDPI displays
#define SC_WINDOW_MIN_WIDTH 360
#define SC_WINDOW_MIN_HEIGHT 540
// The invisible margin around a borderless window, which holds its resize
// edges, in window coordinates
#define SC_WINDOW_MARGIN 4
// How far a corner resize extends along the edges, beyond the margin
#define SC_WINDOW_CORNER_EXTENT 16
// The drag area: a fraction of the display size, fixed when the window resizes
#define SC_WINDOW_CORNER_WIDTH_RATIO 0.05f
#define SC_WINDOW_CORNER_HEIGHT_RATIO 0.025f
#define SC_WINDOW_CLICK_DELAY SC_TICK_FROM_MS(220)
#define SC_WINDOW_CLICK_MOVE_TOLERANCE 8.0f
#define SC_WINDOW_BORDER 2
#define SC_WINDOW_BORDER_GRAY 0x33

// xdg_surface.set_window_geometry, see xdg-shell.xml
#define SC_XDG_SURFACE_SET_WINDOW_GEOMETRY 3

static float
sc_ika_window_get_content_scale(SDL_Window *window) {
    SDL_DisplayID display = SDL_GetDisplayForWindow(window);
    float scale = display ? SDL_GetDisplayContentScale(display) : 0;
    return scale > 0 ? scale : 1;
}

static float
sc_ika_window_get_pixel_density(SDL_Window *window) {
    float density = SDL_GetWindowPixelDensity(window);
    return density > 0 ? density : 1;
}

static bool
sc_ika_window_is_constrained(SDL_Window *window) {
    return SDL_GetWindowFlags(window) & (SDL_WINDOW_FULLSCREEN
                                       | SDL_WINDOW_MAXIMIZED);
}

static enum sc_ika_window_margin_backend
sc_ika_window_get_margin_backend(bool borderless) {
    const char *driver = SDL_GetCurrentVideoDriver();
    if (!borderless || !driver) {
        return SC_IKA_WINDOW_MARGIN_NONE;
    }
    if (!strcmp(driver, "wayland")) {
        return SC_IKA_WINDOW_MARGIN_WAYLAND;
    }
    if (!strcmp(driver, "x11")) {
        return SC_IKA_WINDOW_MARGIN_X11;
    }
    return SC_IKA_WINDOW_MARGIN_NONE;
}

SDL_WindowFlags
sc_ika_window_get_creation_flags(bool borderless) {
    // The margin is transparent
    return sc_ika_window_get_margin_backend(borderless)
                != SC_IKA_WINDOW_MARGIN_NONE ? SDL_WINDOW_TRANSPARENT : 0;
}

// Whether (x, y), in window coordinates, is in the drag area (relative to the
// content)
static bool
sc_ika_window_is_in_corner(struct sc_ika_window *iw, float x, float y) {
    SDL_Rect bounds = {0};
    SDL_DisplayID display = SDL_GetDisplayForWindow(iw->window);
    if (!display || !SDL_GetDisplayBounds(display, &bounds)) {
        return false;
    }
    x -= iw->margin;
    y -= iw->margin;
    float w = bounds.w * SC_WINDOW_CORNER_WIDTH_RATIO;
    float h = bounds.h * SC_WINDOW_CORNER_HEIGHT_RATIO;
    // Not the outermost content pixel, next to the resize edges
    return x >= 1 && y >= 1 && x < 1 + w && y < 1 + h;
}

static bool
sc_ika_window_is_in_content(struct sc_ika_window *iw, float x, float y) {
    int w, h;
    if (!iw->margin || !SDL_GetWindowSize(iw->window, &w, &h)) {
        return true;
    }
    int m = iw->margin;
    return x >= m && y >= m && x < w - m && y < h - m;
}

static SDL_HitTestResult SDLCALL
sc_ika_window_hit_test(SDL_Window *window, const SDL_Point *area, void *data) {
    struct sc_ika_window *iw = data;

    SDL_WindowFlags flags = SDL_GetWindowFlags(window);
    if (!(flags & SDL_WINDOW_BORDERLESS)
            || (flags & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_MAXIMIZED))) {
        return SDL_HITTEST_NORMAL;
    }

    int w, h;
    if (!SDL_GetWindowSize(window, &w, &h)) {
        return SDL_HITTEST_NORMAL;
    }

    // Without a margin, the resize edges are inside the content
    int edge = iw->margin ? iw->margin : SC_WINDOW_MARGIN;
    int corner = edge + SC_WINDOW_CORNER_EXTENT;
    bool left = area->x < edge;
    bool right = area->x >= w - edge;
    bool top = area->y < edge;
    bool bottom = area->y >= h - edge;
    bool near_left = area->x < corner;
    bool near_right = area->x >= w - corner;
    bool near_top = area->y < corner;
    bool near_bottom = area->y >= h - corner;

    bool resizable = flags & SDL_WINDOW_RESIZABLE;
    if (resizable) {
        if ((top && near_left) || (left && near_top)) {
            return SDL_HITTEST_RESIZE_TOPLEFT;
        }
        if ((top && near_right) || (right && near_top)) {
            return SDL_HITTEST_RESIZE_TOPRIGHT;
        }
        if ((bottom && near_left) || (left && near_bottom)) {
            return SDL_HITTEST_RESIZE_BOTTOMLEFT;
        }
        if ((bottom && near_right) || (right && near_bottom)) {
            return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        }
    }

    // Without decorations, the window is moved from the top-left corner of its
    // content (before the top and left edges without a margin, so that a drag
    // starts immediately)
    if (sc_ika_window_is_in_corner(iw, area->x, area->y)) {
        return SDL_HITTEST_DRAGGABLE;
    }

    if (resizable) {
        if (top) {
            return SDL_HITTEST_RESIZE_TOP;
        }
        if (bottom) {
            return SDL_HITTEST_RESIZE_BOTTOM;
        }
        if (left) {
            return SDL_HITTEST_RESIZE_LEFT;
        }
        if (right) {
            return SDL_HITTEST_RESIZE_RIGHT;
        }
    }

    return SDL_HITTEST_NORMAL;
}

// Tell the Wayland compositor which part of the surface is the window
static void
sc_ika_window_set_wayland_geometry(struct sc_ika_window *iw, int x, int y,
                                   int w, int h) {
    SDL_PropertiesID props = SDL_GetWindowProperties(iw->window);
    void *xdg_surface =
        SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_XDG_SURFACE_POINTER,
                               NULL);
    if (!xdg_surface || !iw->wayland || w <= 0 || h <= 0) {
        return;
    }

    typedef void *(*marshal_flags_fn)(void *, uint32_t, const void *, uint32_t,
                                      uint32_t, ...);
    typedef uint32_t (*get_version_fn)(void *);
    typedef void (*marshal_fn)(void *, uint32_t, ...);
    marshal_flags_fn marshal_flags =
        (marshal_flags_fn) dlsym(iw->wayland, "wl_proxy_marshal_flags");
    get_version_fn get_version =
        (get_version_fn) dlsym(iw->wayland, "wl_proxy_get_version");
    if (marshal_flags && get_version) {
        marshal_flags(xdg_surface, SC_XDG_SURFACE_SET_WINDOW_GEOMETRY, NULL,
                      get_version(xdg_surface), 0, (int32_t) x, (int32_t) y,
                      (int32_t) w, (int32_t) h);
        return;
    }

    // libwayland-client < 1.20
    marshal_fn marshal = (marshal_fn) dlsym(iw->wayland, "wl_proxy_marshal");
    if (marshal) {
        marshal(xdg_surface, SC_XDG_SURFACE_SET_WINDOW_GEOMETRY, (int32_t) x,
                (int32_t) y, (int32_t) w, (int32_t) h);
    }
}

// Call fn on the X11 display and window, with libX11 already loaded by SDL (so
// that scrcpy does not link it)
static void
sc_ika_window_with_x11(SDL_Window *window,
                       void (*fn)(void *x11, void *display,
                                  unsigned long xwindow, void *userdata),
                       void *userdata) {
    SDL_PropertiesID props = SDL_GetWindowProperties(window);
    void *display =
        SDL_GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER,
                               NULL);
    Sint64 xwindow =
        SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    if (!display || !xwindow) {
        return;
    }

    void *x11 = dlopen("libX11.so.6", RTLD_LAZY | RTLD_NOLOAD);
    if (!x11) {
        return;
    }
    fn(x11, display, (unsigned long) xwindow, userdata);
    dlclose(x11);
}

typedef unsigned long (*sc_x_intern_atom_fn)(void *, const char *, int);
typedef int (*sc_x_change_property_fn)(void *, unsigned long, unsigned long,
                                       unsigned long, int, int,
                                       const unsigned char *, int);
typedef int (*sc_x_flush_fn)(void *);

// Tell the X11 window manager which part of the window is its frame (as GTK
// does for the shadow of client-side decorations)
static void
sc_ika_window_set_x11_frame_extents_cb(void *x11, void *display,
                                       unsigned long xwindow, void *userdata) {
    long extent = *(const long *) userdata;
    sc_x_intern_atom_fn intern_atom =
        (sc_x_intern_atom_fn) dlsym(x11, "XInternAtom");
    sc_x_change_property_fn change_property =
        (sc_x_change_property_fn) dlsym(x11, "XChangeProperty");
    sc_x_flush_fn flush = (sc_x_flush_fn) dlsym(x11, "XFlush");
    if (!intern_atom || !change_property || !flush) {
        return;
    }

    // left, right, top, bottom; 32-bit data is passed as longs to Xlib
    long extents[4] = {extent, extent, extent, extent};
    unsigned long property = intern_atom(display, "_GTK_FRAME_EXTENTS", 0);
    // XA_CARDINAL (6), PropModeReplace (0)
    change_property(display, xwindow, property, 6, 32, 0,
                    (const unsigned char *) extents, 4);
    flush(display);
}

#ifdef __linux__
// On X11, the window manager draws the title bar, and GNOME picks its dark
// variant from the _GTK_THEME_VARIANT property. Take the variant from GTK_THEME
// (for example "Adwaita:dark"), which already reaches the title bar through
// libdecor's GTK plugin on Wayland.
static void
sc_ika_window_set_gtk_theme_variant_cb(void *x11, void *display,
                                       unsigned long xwindow, void *userdata) {
    (void) userdata;
    sc_x_intern_atom_fn intern_atom =
        (sc_x_intern_atom_fn) dlsym(x11, "XInternAtom");
    sc_x_change_property_fn change_property =
        (sc_x_change_property_fn) dlsym(x11, "XChangeProperty");
    sc_x_flush_fn flush = (sc_x_flush_fn) dlsym(x11, "XFlush");
    if (!intern_atom || !change_property || !flush) {
        return;
    }

    static const char dark[] = "dark";
    unsigned long property = intern_atom(display, "_GTK_THEME_VARIANT", 0);
    unsigned long utf8 = intern_atom(display, "UTF8_STRING", 0);
    // 8-bit format, PropModeReplace (0)
    change_property(display, xwindow, property, utf8, 8, 0,
                    (const unsigned char *) dark, sizeof(dark) - 1);
    flush(display);
}

static void
sc_ika_window_apply_gtk_theme_variant(SDL_Window *window) {
    const char *driver = SDL_GetCurrentVideoDriver();
    const char *theme = getenv("GTK_THEME");
    const char *variant = theme ? strrchr(theme, ':') : NULL;
    if (driver && !strcmp(driver, "x11") && variant
            && !strcmp(variant + 1, "dark")) {
        sc_ika_window_with_x11(window, sc_ika_window_set_gtk_theme_variant_cb,
                               NULL);
    }
}
#endif

static void
sc_ika_window_apply_margin(struct sc_ika_window *iw) {
    int w, h;
    if (!SDL_GetWindowSize(iw->window, &w, &h)) {
        return;
    }

    int m = iw->margin;
    if (iw->margin_backend == SC_IKA_WINDOW_MARGIN_WAYLAND) {
        sc_ika_window_set_wayland_geometry(iw, m, m, w - 2 * m, h - 2 * m);
    } else if (iw->margin_backend == SC_IKA_WINDOW_MARGIN_X11) {
        // The X11 frame extents are in pixels
        long extent = m * sc_ika_window_get_pixel_density(iw->window) + 0.5f;
        sc_ika_window_with_x11(iw->window,
                               sc_ika_window_set_x11_frame_extents_cb,
                               &extent);
    }
}

void
sc_ika_window_init(struct sc_ika_window *iw, SDL_Window *window) {
    iw->window = window;
    iw->corner_press = false;

    bool borderless = SDL_GetWindowFlags(window) & SDL_WINDOW_BORDERLESS;
    iw->margin_backend = sc_ika_window_get_margin_backend(borderless);
    iw->margin = iw->margin_backend != SC_IKA_WINDOW_MARGIN_NONE
               ? SC_WINDOW_MARGIN : 0;
    iw->expected_width = 0;
    iw->expected_height = 0;
    iw->compositor_width = 0;
    iw->compositor_height = 0;
    iw->snap_width = 0;
    iw->snap_height = 0;
    iw->wayland = NULL;
    if (iw->margin_backend == SC_IKA_WINDOW_MARGIN_WAYLAND) {
        iw->wayland = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_NOLOAD);
        if (!iw->wayland) {
            LOGW("libwayland-client not loaded, no window margin");
            iw->margin_backend = SC_IKA_WINDOW_MARGIN_NONE;
            iw->margin = 0;
        }
    }

    sc_ika_window_update_min_size(iw);

    if (!SDL_SetWindowHitTest(window, sc_ika_window_hit_test, iw)) {
        LOGW("Could not set window hit test: %s", SDL_GetError());
    }

#ifdef __linux__
    sc_ika_window_apply_gtk_theme_variant(window);
#endif
}

void
sc_ika_window_destroy(struct sc_ika_window *iw) {
    if (iw->wayland) {
        dlclose(iw->wayland);
    }
}

struct sc_size
sc_ika_window_get_content_size(struct sc_ika_window *iw) {
    int w, h;
    if (!SDL_GetWindowSize(iw->window, &w, &h)) {
        return (struct sc_size) {0, 0};
    }
    w = MAX(w - 2 * iw->margin, 1);
    h = MAX(h - 2 * iw->margin, 1);
    return (struct sc_size) {MIN(w, 0xFFFF), MIN(h, 0xFFFF)};
}

SDL_Rect
sc_ika_window_get_content_pixel_rect(struct sc_ika_window *iw) {
    int w, h;
    if (!SDL_GetWindowSizeInPixels(iw->window, &w, &h)) {
        return (SDL_Rect) {0, 0, 0, 0};
    }
    int m = iw->margin * sc_ika_window_get_pixel_density(iw->window) + 0.5f;
    return (SDL_Rect) {m, m, MAX(w - 2 * m, 1), MAX(h - 2 * m, 1)};
}

// The largest length, at most 3 points shorter, whose size in pixels is even
static int
sc_ika_window_snap_length(int length, float density) {
    for (int i = 0; i < 4 && length - i > 1; ++i) {
        int pixels = (int) SDL_roundf((length - i) * density);
        if (!(pixels & 1)) {
            return length - i;
        }
    }
    return length;
}

void
sc_ika_window_set_content_size(struct sc_ika_window *iw, struct sc_size size) {
    // The margin is applied on change if the window is maximized or fullscreen
    int m = sc_ika_window_is_constrained(iw->window) ? 0 : iw->margin;
    int w = size.width + 2 * m;
    int h = size.height + 2 * m;
    if (!sc_ika_window_is_constrained(iw->window)) {
        float density = sc_ika_window_get_pixel_density(iw->window);
        w = sc_ika_window_snap_length(w, density);
        h = sc_ika_window_snap_length(h, density);
    }
    iw->expected_width = w;
    iw->expected_height = h;
    if (!SDL_SetWindowSize(iw->window, w, h)) {
        LOGW("Could not set window size: %s", SDL_GetError());
    }
    sc_ika_window_apply_margin(iw);
}

void
sc_ika_window_snap_even(struct sc_ika_window *iw) {
    if (sc_ika_window_is_constrained(iw->window)) {
        return;
    }

    int pw, ph, w, h;
    if (!SDL_GetWindowSizeInPixels(iw->window, &pw, &ph)
            || !SDL_GetWindowSize(iw->window, &w, &h)
            || w <= 0 || h <= 0) {
        return;
    }
    if (!(pw & 1) && !(ph & 1)) {
        iw->snap_width = 0;
        iw->snap_height = 0;
        return;
    }
    if (w == iw->snap_width && h == iw->snap_height) {
        // Already tried from this size: the compositor keeps it (a tiled
        // window)
        return;
    }
    iw->snap_width = w;
    iw->snap_height = h;

    // The density that the compositor gave, to find a size that rounds to even
    int nw = (pw & 1) ? sc_ika_window_snap_length(w, (float) pw / w) : w;
    int nh = (ph & 1) ? sc_ika_window_snap_length(h, (float) ph / h) : h;
    iw->expected_width = nw;
    iw->expected_height = nh;
    if (!SDL_SetWindowSize(iw->window, nw, nh)) {
        LOGW("Could not set window size: %s", SDL_GetError());
    }
    sc_ika_window_apply_margin(iw);
}

void
sc_ika_window_on_changed(struct sc_ika_window *iw) {
    if (iw->margin_backend == SC_IKA_WINDOW_MARGIN_NONE) {
        return;
    }

    bool constrained = sc_ika_window_is_constrained(iw->window);
    int margin = constrained ? 0 : SC_WINDOW_MARGIN;
    bool margin_changed = margin != iw->margin;
    iw->margin = margin;

    if (iw->margin_backend == SC_IKA_WINDOW_MARGIN_WAYLAND) {
        int w, h;
        bool has_size = SDL_GetWindowSize(iw->window, &w, &h);
        if (!margin) {
            // Resize on restore
            iw->expected_width = 0;
            iw->expected_height = 0;
            iw->compositor_width = 0;
            iw->compositor_height = 0;
        } else if (has_size && w == iw->expected_width
                            && h == iw->expected_height) {
            // The margin was added
            iw->compositor_width = 0;
            iw->compositor_height = 0;
        } else if (has_size) {
            // Unless the compositor insists on the size it gave just before
            if (w != iw->compositor_width || h != iw->compositor_height) {
                // The compositor sized the window geometry, which is the
                // content: add the margin
                iw->compositor_width = w;
                iw->compositor_height = h;
                iw->expected_width = w + 2 * margin;
                iw->expected_height = h + 2 * margin;
                if (!SDL_SetWindowSize(iw->window, iw->expected_width,
                                       iw->expected_height)) {
                    LOGW("Could not set window size: %s", SDL_GetError());
                }
            }
        }
    }

    sc_ika_window_apply_margin(iw);
    if (margin_changed) {
        sc_ika_window_update_min_size(iw);
        if (iw->margin_backend == SC_IKA_WINDOW_MARGIN_X11 && margin) {
            // On restore, the window manager gives the window the size of
            // its frame, saved without a margin: add it around
            int x, y, w, h;
            if (SDL_GetWindowPosition(iw->window, &x, &y)
                    && SDL_GetWindowSize(iw->window, &w, &h)) {
                SDL_SetWindowSize(iw->window, w + 2 * margin, h + 2 * margin);
                SDL_SetWindowPosition(iw->window, x - margin, y - margin);
            }
        }
    }
}

void
sc_ika_window_update_min_size(struct sc_ika_window *iw) {
    float scale = MAX(sc_ika_window_get_content_scale(iw->window), 1);
    int w = SC_WINDOW_MIN_WIDTH * scale + 0.5f + 2 * iw->margin;
    int h = SC_WINDOW_MIN_HEIGHT * scale + 0.5f + 2 * iw->margin;
    if (!SDL_SetWindowMinimumSize(iw->window, w, h)) {
        LOGW("Could not set window minimum size: %s", SDL_GetError());
    }
}

bool
sc_ika_window_handle_event(struct sc_ika_window *iw, const SDL_Event *event) {
    switch (event->type) {
        case SDL_EVENT_MOUSE_BUTTON_DOWN: {
            iw->corner_press = false;
            if (!sc_ika_window_is_in_content(iw, event->button.x,
                                             event->button.y)) {
                // In the margin, owned by the resize edges
                return true;
            }
            if (event->button.button != SDL_BUTTON_LEFT) {
                return false;
            }
            if (!sc_ika_window_is_constrained(iw->window)
                    || !sc_ika_window_is_in_corner(iw, event->button.x,
                                                   event->button.y)) {
                return false;
            }
            iw->corner_press = true;
            iw->corner_press_tick = sc_tick_now();
            iw->corner_press_x = event->button.x;
            iw->corner_press_y = event->button.y;
            return true;
        }
        case SDL_EVENT_MOUSE_MOTION:
            if (iw->corner_press) {
                float dx = event->motion.x - iw->corner_press_x;
                float dy = event->motion.y - iw->corner_press_y;
                if (dx * dx + dy * dy > SC_WINDOW_CLICK_MOVE_TOLERANCE
                                      * SC_WINDOW_CLICK_MOVE_TOLERANCE) {
                    iw->corner_press = false;
                }
            }
            // Hovering the margin is not for the device (but a drag that
            // started in the content continues)
            return !event->motion.state
                && !sc_ika_window_is_in_content(iw, event->motion.x,
                                                event->motion.y);
        case SDL_EVENT_MOUSE_WHEEL:
            return !sc_ika_window_is_in_content(iw, event->wheel.mouse_x,
                                                event->wheel.mouse_y);
        case SDL_EVENT_MOUSE_BUTTON_UP: {
            if (!iw->corner_press || event->button.button != SDL_BUTTON_LEFT) {
                return false;
            }
            iw->corner_press = false;
            if (sc_tick_now() - iw->corner_press_tick > SC_WINDOW_CLICK_DELAY) {
                return true;
            }
            SDL_WindowFlags flags = SDL_GetWindowFlags(iw->window);
            if (flags & SDL_WINDOW_FULLSCREEN) {
                if (!SDL_SetWindowFullscreen(iw->window, false)) {
                    LOGW("Could not leave fullscreen: %s", SDL_GetError());
                }
            } else if (flags & SDL_WINDOW_MAXIMIZED) {
                if (!SDL_RestoreWindow(iw->window)) {
                    LOGW("Could not restore window: %s", SDL_GetError());
                }
            }
            return true;
        }
        default:
            return false;
    }
}

void
sc_ika_window_render_border(struct sc_ika_window *iw, SDL_Renderer *renderer) {
    SDL_WindowFlags flags = SDL_GetWindowFlags(iw->window);
    if (!(flags & SDL_WINDOW_BORDERLESS) || (flags & SDL_WINDOW_FULLSCREEN)) {
        return;
    }

    SDL_Rect content = sc_ika_window_get_content_pixel_rect(iw);
    if (content.w < 2 * SC_WINDOW_BORDER || content.h < 2 * SC_WINDOW_BORDER) {
        return;
    }

    const float t = SC_WINDOW_BORDER;
    float x = content.x;
    float y = content.y;
    float w = content.w;
    float h = content.h;
    SDL_FRect rects[] = {
        {x, y, w, t},
        {x, y + h - t, w, t},
        {x, y + t, t, h - 2 * t},
        {x + w - t, y + t, t, h - 2 * t},
    };
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_NONE);
    SDL_SetRenderDrawColor(renderer, SC_WINDOW_BORDER_GRAY,
                           SC_WINDOW_BORDER_GRAY, SC_WINDOW_BORDER_GRAY, 0xFF);
    SDL_RenderFillRects(renderer, rects, ARRAY_LEN(rects));
}

struct sc_size
sc_ika_window_get_windowed_size(struct sc_ika_window *iw,
                                struct sc_size previous) {
    SDL_WindowFlags flags = SDL_GetWindowFlags(iw->window);
    // The compositor chooses the size in these modes, keep the windowed one
    if (flags & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_MAXIMIZED
                                       | SDL_WINDOW_MINIMIZED)) {
        return previous;
    }

    struct sc_size size = sc_ika_window_get_content_size(iw);
    return size.width && size.height ? size : previous;
}

bool
sc_ika_window_save_state(const char *path, struct sc_size windowed_size,
                         bool fullscreen) {
    if (!windowed_size.width || !windowed_size.height) {
        LOGW("No windowed size, window state not saved");
        return false;
    }

    char *tmp_path;
    if (asprintf(&tmp_path, "%s.tmp.%ld", path, (long) getpid()) == -1) {
        LOG_OOM();
        return false;
    }

    FILE *file = fopen(tmp_path, "w");
    if (!file) {
        LOGW("Could not open %s: %s", tmp_path, strerror(errno));
        free(tmp_path);
        return false;
    }

    bool ok = fprintf(file, "version=1\nwidth=%u\nheight=%u\nfullscreen=%s\n",
                      windowed_size.width, windowed_size.height,
                      fullscreen ? "true" : "false") > 0;
    ok &= fflush(file) == 0;
    ok &= fsync(fileno(file)) == 0;
    ok &= fclose(file) == 0;
    ok = ok && rename(tmp_path, path) == 0;
    if (!ok) {
        LOGW("Could not save window state to %s: %s", path, strerror(errno));
        unlink(tmp_path);
    }
    free(tmp_path);
    return ok;
}
