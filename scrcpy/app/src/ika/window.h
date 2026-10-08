#ifndef SC_IKA_WINDOW_H
#define SC_IKA_WINDOW_H

#include "common.h"

#include <stdbool.h>
#include <SDL3/SDL.h>

#include "coords.h"
#include "util/tick.h"

/**
 * Window chrome of Ika windows: minimum size, and for a borderless window,
 * resize edges, a drag area in the top-left corner and a thin border.
 *
 * A borderless window has no decorations to resize it from, so on Wayland and
 * X11 it gets an invisible margin, outside of its content, like the shadow of
 * client-side decorations: the compositor is told that the window is the
 * content (Wayland window geometry, X11 _GTK_FRAME_EXTENTS), and the margin
 * holds the resize edges. Maximized and fullscreen windows have no margin.
 *
 * In fullscreen or maximized, a click in the top-left corner leaves it.
 */
struct sc_ika_window {
    SDL_Window *window;

    enum sc_ika_window_margin_backend {
        SC_IKA_WINDOW_MARGIN_NONE,
        SC_IKA_WINDOW_MARGIN_WAYLAND,
        SC_IKA_WINDOW_MARGIN_X11,
    } margin_backend;
    int margin; // current margin, in window coordinates

    // Wayland: the window size with its margin, as last requested
    int expected_width;
    int expected_height;
    // Wayland: the size given by the compositor that the margin was last added
    // to (if it insists on it, as for a tiled window, the margin is inside)
    int compositor_width;
    int compositor_height;

    // libwayland-client, already loaded by SDL
    void *wayland;

    // A left click started in the corner of a fullscreen/maximized window
    bool corner_press;
    sc_tick corner_press_tick;
    float corner_press_x;
    float corner_press_y;
};

// Window flags to create a window with (before sc_ika_window_init())
SDL_WindowFlags
sc_ika_window_get_creation_flags(bool borderless);

void
sc_ika_window_init(struct sc_ika_window *iw, SDL_Window *window);

void
sc_ika_window_destroy(struct sc_ika_window *iw);

// The margin around the content, in window coordinates
static inline int
sc_ika_window_get_margin(struct sc_ika_window *iw) {
    return iw->margin;
}

// The size of the content (the window without its margin)
struct sc_size
sc_ika_window_get_content_size(struct sc_ika_window *iw);

// The content area in pixels
SDL_Rect
sc_ika_window_get_content_pixel_rect(struct sc_ika_window *iw);

// Resize the window so that its content has this size
void
sc_ika_window_set_content_size(struct sc_ika_window *iw, struct sc_size size);

// Update the margin when the window size or state has changed
void
sc_ika_window_on_changed(struct sc_ika_window *iw);

// Update the minimum size after the window moved to a display with another
// scale
void
sc_ika_window_update_min_size(struct sc_ika_window *iw);

// Return true if the event is consumed (a click in the corner, or a pointer
// event in the margin)
bool
sc_ika_window_handle_event(struct sc_ika_window *iw, const SDL_Event *event);

// Draw the border of a borderless window, around the content
void
sc_ika_window_render_border(struct sc_ika_window *iw, SDL_Renderer *renderer);

// The size to restore the window content to: its current size if windowed
struct sc_size
sc_ika_window_get_windowed_size(struct sc_ika_window *iw,
                                struct sc_size previous);

// Write "version=1, width, height, fullscreen" to path (atomically)
bool
sc_ika_window_save_state(const char *path, struct sc_size windowed_size,
                         bool fullscreen);

#endif
