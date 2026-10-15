#ifndef SC_FLEX_H
#define SC_FLEX_H

#include "common.h"

#include <stdbool.h>
#include <SDL3/SDL.h>
#include <libavutil/frame.h>

#include "controller.h"
#include "coords.h"
#include "util/tick.h"

// Minimum display size, must match MIN_WIDTH/MIN_HEIGHT in the server
// PrimaryDisplayResizer (the server raises smaller requests to it)
#define SC_FLEX_MIN_WIDTH 360
#define SC_FLEX_MIN_HEIGHT 540

#define SC_FLEX_BLUR_LEVELS 3
// Display sizes requested recently, to recognize late frames drawn at one
#define SC_FLEX_RECENT_SIZES 8

/**
 * Flex display: the device display follows the window size, in pixels, so that
 * it is shown 1:1.
 *
 * Resize requests are debounced while the window is being resized. Meanwhile,
 * the window "holds": it shows the last completely drawn content stretched to
 * the window, blurred, until the device has drawn the window size. If the
 * device completes an intermediate size while the window is still being
 * resized, that content becomes the stretched one.
 *
 * For video frames (a new display), each frame is complete and has the display
 * size: the latest one is stretched, and the hold ends with the first frame at
 * the window size.
 *
 * For Cuttlefish frames (raw), the frames always have the physical display
 * size, and the display content is drawn 1:1 in it. The size of that content
 * is only known once the device confirms a resize (DISPLAY_READY), and the
 * guest has drawn it once it stops presenting frames, so the hold shows a
 * captured preview.
 */
struct sc_flex {
    struct sc_controller *controller;
    SDL_Renderer *renderer;
    bool raw;
    // The device confirms the initial size once the app is started on the
    // resized display (raw only)
    bool app_window;

    // In pixels, in device orientation
    struct sc_size pending; // window size, to request once it settles
    sc_tick pending_deadline;
    struct sc_size requested; // last request sent
    struct sc_size shown; // display size of the shown content (raw only)

    sc_tick state_change_tick; // last maximize/fullscreen change
    sc_tick ready_tick; // DISPLAY_READY received for the requested size
    bool ready_unchanged; // the requested size was already the shown one
    sc_tick frame_tick; // last frame received
    // Raw frames received since the last resize request
    unsigned frames_since_request;

    // Raw only
    bool holding;
    bool revealed; // content shown at least once
    SDL_Texture *preview; // the last completely drawn content
    // The guest has drawn an intermediate size while the window was still
    // being resized: capture it as the new preview
    bool refresh_preview;
    sc_tick hold_tick; // blur fade-in start
    sc_tick release_tick; // blur fade-out (or reveal) start
    bool release_reveal; // the release reveals the window content
    // Shown until the content is first revealed, and faded from: the
    // background color of the Android theme
    uint8_t background[3]; // RGB

    // Raw only: the display sizes requested recently (a ring), and the last
    // request time. After a resize, a late frame can still have the content
    // of one of them, surrounded by black (the rest of the physical display).
    struct sc_size recent_sizes[SC_FLEX_RECENT_SIZES];
    unsigned recent_next;
    sc_tick request_tick;
    // The content of the last frame in frame coordinates, if it is a late
    // frame of another size than the shown one
    bool has_late_content;
    SDL_FRect late_content;

    SDL_Texture *blur_levels[SC_FLEX_BLUR_LEVELS];
    struct sc_size blur_source_size;
    bool preview_blur_valid; // blur_levels[0] holds the preview blur

    SDL_TimerID timer;
    sc_tick timer_deadline;
};

void
sc_flex_init(struct sc_flex *flex, struct sc_controller *controller,
             SDL_Renderer *renderer, bool raw, bool app_window);

void
sc_flex_destroy(struct sc_flex *flex);

// The window has a new size in pixels (in device orientation). For raw frames,
// live/live_src is the current content, captured as the preview if a hold
// starts.
void
sc_flex_on_window_size(struct sc_flex *flex, struct sc_size size,
                       SDL_Texture *live, const SDL_FRect *live_src);

// The window was maximized, restored, or switched fullscreen: the next resize
// is not an interactive drag
void
sc_flex_on_window_state_changed(struct sc_flex *flex);

void
sc_flex_on_display_ready(struct sc_flex *flex, struct sc_size size);

// A raw frame was received: recognize a late frame of a recently requested
// display size (only its content is drawn, the rest in the theme background)
void
sc_flex_on_raw_frame_pixels(struct sc_flex *flex, const AVFrame *frame);

// Set the background color of the Android theme (0xAARRGGBB, alpha ignored).
// Return true if it is currently visible, so the screen must be rendered.
bool
sc_flex_set_background(struct sc_flex *flex, uint32_t color);

// A frame was received (frame_size is only used for video frames, which have
// the display size)
void
sc_flex_on_frame(struct sc_flex *flex, struct sc_size frame_size);

// Handle SC_EVENT_FLEX_TIMER, return true if the window must be rendered
bool
sc_flex_on_timer(struct sc_flex *flex);

static inline bool
sc_flex_is_holding(struct sc_flex *flex) {
    return flex->holding;
}

// The display size of the shown content (raw only), 0x0 if none yet
static inline struct sc_size
sc_flex_get_shown_size(struct sc_flex *flex) {
    return flex->shown;
}

// Render the window content for raw frames: the preview during a hold,
// otherwise the live texture (src of it) with the release effects
bool
sc_flex_render_raw(struct sc_flex *flex, SDL_Texture *live,
                   const SDL_FRect *live_src, const SDL_FRect *dst);

// For video frames: render the blur over the frame rendered at dst while the
// window is resized, and its fade-out
bool
sc_flex_render_overlay(struct sc_flex *flex, SDL_Texture *live,
                       const SDL_FRect *dst);

#endif
