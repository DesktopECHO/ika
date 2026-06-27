#include "screen.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
# include <unistd.h>
#endif
#include <SDL3/SDL.h>

#include "events.h"
#include "icon.h"
#include "options.h"
#include "util/log.h"
#include "util/process.h"
#include "util/sdl.h"

#define DISPLAY_MARGIN_PX 96
#define FLEX_DISPLAY_REQUEST_MIN_INTERVAL SC_TICK_FROM_MS(300)
#define FLEX_DISPLAY_RESIZE_QUIET_DELAY SC_TICK_FROM_MS(400)
#define FLEX_DISPLAY_POST_READY_FRAME_GRACE SC_TICK_FROM_MS(150)
#define FLEX_DISPLAY_INITIAL_SHOW_TIMEOUT SC_TICK_FROM_MS(1000)
// Extra time the window stays hidden after the guest first renders at the
// target resolution, letting a freshly-booted desktop finish drawing before the
// window is revealed.
#define FLEX_DISPLAY_SHOW_SETTLE_GRACE SC_TICK_FROM_MS(1000)
#define RAW_FRAME_RESIZE_THROTTLE_WINDOW SC_TICK_FROM_MS(1000)
#define RAW_FRAME_RESIZE_RENDER_INTERVAL SC_TICK_FROM_MS(33)
// Minimum window size at display content scale 1.0; scaled at runtime on HiDPI.
#define SC_WINDOW_MIN_WIDTH 360
#define SC_WINDOW_MIN_HEIGHT 540
// Resize-border thickness in logical points at content scale 1.0; scaled by the
// window's display content scale so it grows on HiDPI/retina displays.
#define SC_WINDOW_RESIZE_BORDER 8
#define SC_WINDOW_DRAG_HOTSPOT_WIDTH_RATIO 0.05f
#define SC_WINDOW_DRAG_HOTSPOT_HEIGHT_RATIO 0.025f
#define SC_WINDOW_DRAG_HOLD_DELAY SC_TICK_FROM_MS(220)
#define SC_WINDOW_CLICK_MOVE_TOLERANCE 8.0f
// Blur effect parameters: jittered ghost copies of the texture drawn at low
// alpha and fractional pixel offsets, producing a cheap soft-blur look without
// a real shader pass.
//   _STEP  - pixel scale for the sample offsets. Larger = wider blur.
//   _ALPHA - per-ghost alpha (0-255) at full intensity. Scaled down as the
//            fade decays so the blur softly disappears.
#define FLEX_DISPLAY_BLUR_STEP 2.15f
#define FLEX_DISPLAY_BLUR_ALPHA 5
// Blur fade-in duration while the resize is unsettled. This ramps the ghost
// overlay in gradually instead of snapping to full blur as soon as the window
// changes size.
#define FLEX_DISPLAY_BLUR_FADE_IN_DURATION SC_TICK_FROM_MS(125)
// Keep the captured preview fully opaque for a brief moment after release so
// a one-frame transitional live buffer is not revealed underneath the fade.
#define FLEX_DISPLAY_PREVIEW_REVEAL_DELAY SC_TICK_FROM_MS(650)
// Blur fade-out duration. When the resize hold releases, the blur ghost intensity
// decays linearly to 0.0 over this period rather than snapping off in one
// frame. The underlying texture has already been swapped to the new content by
// the time the fade begins, so the fade reveals the new content sharpening up.
#define FLEX_DISPLAY_BLUR_FADE_OUT_DURATION SC_TICK_FROM_MS(450)
// Tick interval driving the fade animation; ~60 Hz is enough for a smooth
// linear ramp without burning CPU.
#define FLEX_DISPLAY_BLUR_FADE_INTERVAL_MS 16

// Hold the prepared window black for at least this long before fading in.
#define SC_WINDOW_FADE_IN_HOLD SC_TICK_FROM_MS(1500)
// Duration of the fade-from-black once the prepared window is revealed.
#define SC_WINDOW_FADE_IN_DURATION SC_TICK_FROM_MS(500)
// Safety cap: begin the fade even if flex_display never reports settled, so
// the window can never stay black indefinitely.
#define SC_WINDOW_FADE_IN_MAX_HOLD SC_TICK_FROM_MS(3000)

#define DOWNCAST(SINK) container_of(SINK, struct sc_screen, frame_sink)

static void
set_aspect_ratio(struct sc_screen *screen, struct sc_size content_size) {
    assert(content_size.width && content_size.height);

    if (screen->window_aspect_ratio_lock) {
        float ar = (float) content_size.width / content_size.height;
        bool ok = SDL_SetWindowAspectRatio(screen->window, ar, ar);
        if (!ok) {
            LOGW("Could not set window aspect ratio: %s", SDL_GetError());
        }
    }
}

static inline struct sc_size
get_oriented_size(struct sc_size size, enum sc_orientation orientation) {
    struct sc_size oriented_size;
    if (sc_orientation_is_swap(orientation)) {
        oriented_size.width = size.height;
        oriented_size.height = size.width;
    } else {
        oriented_size.width = size.width;
        oriented_size.height = size.height;
    }
    return oriented_size;
}

static inline bool
sc_size_is_valid(struct sc_size size) {
    return size.width && size.height;
}

static inline bool
is_windowed(struct sc_screen *screen) {
    return !(SDL_GetWindowFlags(screen->window) & (SDL_WINDOW_FULLSCREEN
                                                 | SDL_WINDOW_MINIMIZED
                                                 | SDL_WINDOW_MAXIMIZED));
}

static float
sc_screen_get_display_content_scale(SDL_Window *window) {
    SDL_DisplayID display = SDL_GetDisplayForWindow(window);
    if (!display) {
        return 1.0f;
    }

    float scale = SDL_GetDisplayContentScale(display);
    return scale > 0.0f ? scale : 1.0f;
}

static uint16_t
sc_screen_scale_min_window_dimension(uint16_t value, float scale) {
    if (scale < 1.0f) {
        scale = 1.0f;
    }

    uint32_t scaled = (uint32_t) (value * scale + 0.5f);
    return scaled > UINT16_MAX ? UINT16_MAX : scaled;
}

static struct sc_size
sc_screen_get_min_window_size(SDL_Window *window) {
    float scale = sc_screen_get_display_content_scale(window);
    struct sc_size size = {
        .width = sc_screen_scale_min_window_dimension(SC_WINDOW_MIN_WIDTH,
                                                      scale),
        .height = sc_screen_scale_min_window_dimension(SC_WINDOW_MIN_HEIGHT,
                                                       scale),
    };
    return size;
}

static void
sc_screen_set_window_min_size(SDL_Window *window) {
    struct sc_size size = sc_screen_get_min_window_size(window);
    if (!SDL_SetWindowMinimumSize(window, size.width, size.height)) {
        LOGW("Could not set window minimum size: %s", SDL_GetError());
    }
}

static inline bool
sc_screen_is_drag_hotspot(SDL_Window *window, float x, float y) {
    // Fraction of the fullscreen (display) size -- a fixed area that does not
    // change when the window is resized.
    int full_w = 0, full_h = 0;
    SDL_Rect bounds;
    SDL_DisplayID display = SDL_GetDisplayForWindow(window);
    if (display && SDL_GetDisplayBounds(display, &bounds)) {
        full_w = bounds.w;
        full_h = bounds.h;
    }
    int hw = (int) (full_w * SC_WINDOW_DRAG_HOTSPOT_WIDTH_RATIO);
    int hh = (int) (full_h * SC_WINDOW_DRAG_HOTSPOT_HEIGHT_RATIO);
    return x >= 0 && y >= 0 && x < hw && y < hh;
}

static void
sc_screen_finalize_hotspot_press(struct sc_screen *screen) {
    if (screen->hotspot_press_started_in_hotspot) {
        screen->hotspot_drag_pending = screen->hotspot_dragged;
    }

    screen->hotspot_button_down = false;
    screen->hotspot_press_started_in_hotspot = false;
    screen->hotspot_dragged = false;
}

static void
sc_screen_poll_hotspot_state(struct sc_screen *screen) {
    if (!screen->hotspot_button_down) {
        return;
    }

    SDL_MouseButtonFlags buttons = SDL_GetGlobalMouseState(NULL, NULL);
    bool left_down = buttons & SDL_BUTTON_LMASK;
    if (!left_down) {
        sc_screen_finalize_hotspot_press(screen);
        return;
    }

    // Long press in hotspot is treated as drag.
    if (!screen->hotspot_dragged) {
        sc_tick now = sc_tick_now();
        if (now - screen->hotspot_press_tick > SC_WINDOW_DRAG_HOLD_DELAY) {
            screen->hotspot_dragged = true;
        }
    }
}

static SDL_HitTestResult SDLCALL
sc_screen_window_hit_test(SDL_Window *window, const SDL_Point *area,
                          void *data) {
    (void) window;

    struct sc_screen *screen = data;
    SDL_MouseButtonFlags buttons = SDL_GetGlobalMouseState(NULL, NULL);
    bool left_down = buttons & SDL_BUTTON_LMASK;
    bool in_hotspot = sc_screen_is_drag_hotspot(screen->window, area->x, area->y);

    if (left_down && !screen->hotspot_button_down) {
        screen->hotspot_button_down = true;
        screen->hotspot_press_started_in_hotspot = in_hotspot;
        screen->hotspot_dragged = false;
        screen->hotspot_press_tick = sc_tick_now();
    } else if (!left_down && screen->hotspot_button_down) {
        sc_screen_finalize_hotspot_press(screen);
    }

    uint64_t flags = SDL_GetWindowFlags(screen->window);
    bool borderless = flags & SDL_WINDOW_BORDERLESS;
    bool resizable = flags & SDL_WINDOW_RESIZABLE;
    bool constrained = flags & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_MAXIMIZED);
    if (!borderless || constrained) {
        return SDL_HITTEST_NORMAL;
    }

    int w;
    int h;
    if (!SDL_GetWindowSize(screen->window, &w, &h)) {
        return SDL_HITTEST_NORMAL;
    }

    float content_scale = sc_screen_get_display_content_scale(window);
    const int border = (int) (SC_WINDOW_RESIZE_BORDER * content_scale);
    bool left = area->x < border;
    bool right = area->x >= w - border;
    bool top = area->y < border;
    bool bottom = area->y >= h - border;

    if (resizable) {
        if (top && left) {
            return SDL_HITTEST_RESIZE_TOPLEFT;
        }
        if (top && right) {
            return SDL_HITTEST_RESIZE_TOPRIGHT;
        }
        if (bottom && left) {
            return SDL_HITTEST_RESIZE_BOTTOMLEFT;
        }
        if (bottom && right) {
            return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        }
    }

    // Custom drag hotspot when title bar/decorations are hidden.
    // Give it priority over top/left edge resize (except corners above), so
    // compositor-driven drag starts immediately.
    if (in_hotspot) {
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

// get the preferred display bounds (i.e. the screen bounds with some margins)
static bool
get_preferred_display_bounds(struct sc_size *bounds) {
    SDL_Rect rect;
    SDL_DisplayID display = SDL_GetPrimaryDisplay();
    if (!display) {
        LOGW("Could not get primary display: %s", SDL_GetError());
        return false;
    }

    bool ok = SDL_GetDisplayUsableBounds(display, &rect);
    if (!ok) {
        LOGW("Could not get display usable bounds: %s", SDL_GetError());
        return false;
    }

    bounds->width = MAX(0, rect.w - DISPLAY_MARGIN_PX);
    bounds->height = MAX(0, rect.h - DISPLAY_MARGIN_PX);
    return true;
}

static bool
is_optimal_size(struct sc_size current_size, struct sc_size content_size) {
    // The size is optimal if we can recompute one dimension of the current
    // size from the other
    return current_size.height == current_size.width * content_size.height
                                                     / content_size.width
        || current_size.width == current_size.height * content_size.width
                                                     / content_size.height;
}

// return the optimal size of the window, with the following constraints:
//  - it attempts to keep at least one dimension of the current_size (i.e. it
//    crops the black borders)
//  - it keeps the aspect ratio
//  - it scales down to make it fit in the display_size
static struct sc_size
get_optimal_size(struct sc_size current_size, struct sc_size content_size,
                 bool within_display_bounds) {
    if (content_size.width == 0 || content_size.height == 0) {
        // avoid division by 0
        return current_size;
    }

    struct sc_size window_size;

    struct sc_size display_size;
    if (!within_display_bounds ||
            !get_preferred_display_bounds(&display_size)) {
        // do not constraint the size
        window_size = current_size;
    } else {
        window_size.width = MIN(current_size.width, display_size.width);
        window_size.height = MIN(current_size.height, display_size.height);
    }

    if (is_optimal_size(window_size, content_size)) {
        return window_size;
    }

    bool keep_width = content_size.width * window_size.height
                    > content_size.height * window_size.width;
    if (keep_width) {
        // remove black borders on top and bottom
        window_size.height = content_size.height * window_size.width
                           / content_size.width;
    } else {
        // remove black borders on left and right (or none at all if it already
        // fits)
        window_size.width = content_size.width * window_size.height
                          / content_size.height;
    }

    return window_size;
}

// initially, there is no current size, so use the frame size as current size
// req_width and req_height, if not 0, are the sizes requested by the user
static inline struct sc_size
get_initial_optimal_size(struct sc_size content_size, uint16_t req_width,
                         uint16_t req_height) {
    struct sc_size window_size;
    if (!req_width && !req_height) {
        window_size = get_optimal_size(content_size, content_size, true);
    } else {
        if (req_width) {
            window_size.width = req_width;
        } else {
            // compute from the requested height
            window_size.width = (uint32_t) req_height * content_size.width
                              / content_size.height;
        }
        if (req_height) {
            window_size.height = req_height;
        } else {
            // compute from the requested width
            window_size.height = (uint32_t) req_width * content_size.height
                               / content_size.width;
        }
    }
    return window_size;
}

static inline bool
sc_screen_is_relative_mode(struct sc_screen *screen) {
    // screen->im.mp may be NULL if --no-control
    return screen->im.mp && screen->im.mp->relative_mode;
}

static inline float
sc_screen_smoothstep(float value) {
    if (value <= 0.0f) {
        return 0.0f;
    }
    if (value >= 1.0f) {
        return 1.0f;
    }

    return value * value * (3.0f - 2.0f * value);
}

static void
compute_content_rect(struct sc_size render_size, struct sc_size content_size,
                     bool can_upscale, enum sc_render_fit render_fit,
                     SDL_FRect *rect) {
    if (render_fit == SC_RENDER_FIT_DISABLED) {
        rect->x = 0;
        rect->y = 0;
        rect->w = content_size.width;
        rect->h = content_size.height;
        return;
    }

    if (is_optimal_size(render_size, content_size)) {
        rect->x = 0;
        rect->y = 0;
        rect->w = render_size.width;
        rect->h = render_size.height;
        return;
    }

    if (!can_upscale && content_size.width <= render_size.width
                     && content_size.height <= render_size.height) {
        // Center without upscaling
        rect->x = (render_size.width - content_size.width) / 2.f;
        rect->y = (render_size.height - content_size.height) / 2.f;
        rect->w = content_size.width;
        rect->h = content_size.height;
        return;
    }

    bool keep_width = content_size.width * render_size.height
                    > content_size.height * render_size.width;
    if (keep_width) {
        rect->x = 0;
        rect->w = render_size.width;
        rect->h = (float) render_size.width * content_size.height
                                            / content_size.width;
        rect->y = (render_size.height - rect->h) / 2.f;
    } else {
        rect->y = 0;
        rect->h = render_size.height;
        rect->w = (float) render_size.height * content_size.width
                                             / content_size.height;
        rect->x = (render_size.width - rect->w) / 2.f;
    }
}

static void
sc_screen_update_content_rect(struct sc_screen *screen) {
    // Only upscale video frames, not icon
    bool can_upscale = screen->video && !screen->disconnected;

    struct sc_size render_size =
        sc_sdl_get_render_output_size(screen->renderer);

    if (screen->flex_display && screen->transient_stretch) {
        screen->rect.x = 0;
        screen->rect.y = 0;
        screen->rect.w = render_size.width;
        screen->rect.h = render_size.height;
        return;
    }

    if (screen->flex_display
            && screen->video
            && !screen->disconnected
            && screen->render_fit != SC_RENDER_FIT_DISABLED) {
        if (screen->resize_display_using_pixel_size
                && screen->last_requested_display_size.width
                && screen->last_requested_display_size.height) {
            // Direct Display requests the guest size in render-output pixels
            // with no codec alignment applied. Keep the rendered frame at
            // exactly that size so the rect and the frame are always 1:1.
            struct sc_size requested_size =
                get_oriented_size(screen->last_requested_display_size,
                                  screen->orientation);
            uint16_t width = MIN(requested_size.width, render_size.width);
            uint16_t height = MIN(requested_size.height, render_size.height);
            screen->rect.x = (render_size.width - width) / 2;
            screen->rect.y = (render_size.height - height) / 2;
            screen->rect.w = width;
            screen->rect.h = height;
        } else {
            // In dpi resize mode, the host window is the source of truth.
            // Once the remote display catches up, continue filling the window
            // instead of falling back to aspect-preserving letterboxing.
            screen->rect.x = 0;
            screen->rect.y = 0;
            screen->rect.w = render_size.width;
            screen->rect.h = render_size.height;
        }
        return;
    }

    compute_content_rect(render_size, screen->content_size, can_upscale,
                         screen->render_fit, &screen->rect);
}

static void
sc_screen_maybe_request_display_resize(struct sc_screen *screen, bool force);
static void
sc_screen_resize_cuttlefish_physical_display(struct sc_screen *screen,
                                             uint16_t width, uint16_t height);
static void
sc_screen_note_raw_frame_resize_activity(struct sc_screen *screen);
static void
sc_screen_show_prepared_window(struct sc_screen *screen);
static void
sc_screen_schedule_initial_window_show_timer(struct sc_screen *screen);
static SDL_TimerID
sc_screen_take_initial_window_show_timer_locked(struct sc_screen *screen);
static Uint32 SDLCALL
sc_screen_initial_window_show_timer(void *userdata, SDL_TimerID timerID,
                                    Uint32 interval);
static Uint32 SDLCALL
sc_screen_raw_frame_refresh_timer(void *userdata, SDL_TimerID timerID,
                                  Uint32 interval);
static void
sc_screen_schedule_raw_frame_refresh_locked(struct sc_screen *screen,
                                            sc_tick now);
static SDL_TimerID
sc_screen_take_raw_frame_refresh_timer_locked(struct sc_screen *screen);
static void
sc_screen_schedule_resize_settle(struct sc_screen *screen);
static void
sc_screen_force_raw_frame_refresh(struct sc_screen *screen);
static void
sc_screen_schedule_resize_settle_after(struct sc_screen *screen,
                                       Uint32 delay_ms);
static Uint32 SDLCALL
sc_screen_resize_settle_timer(void *userdata, SDL_TimerID timerID,
                              Uint32 interval);
static void
sc_screen_start_blur_fade(struct sc_screen *screen);
static void
sc_screen_stop_blur_fade(struct sc_screen *screen);
static float
sc_screen_blur_fade_in_intensity(struct sc_screen *screen);
static float
sc_screen_blur_intensity(struct sc_screen *screen);
static void
sc_screen_start_blur_animation_timer(struct sc_screen *screen);
static bool
sc_screen_render_texture(struct sc_screen *screen, const SDL_FRect *geometry);
static bool
sc_screen_render_texture_with_alpha(struct sc_screen *screen,
                                    const SDL_FRect *geometry, float alpha);
static void
sc_screen_destroy_resize_preview(struct sc_screen *screen);
static bool
sc_screen_capture_resize_preview(struct sc_screen *screen);
static bool
sc_screen_render_resize_preview(struct sc_screen *screen,
                                const SDL_FRect *geometry,
                                float alpha,
                                float intensity);
static bool
sc_screen_render_blurred_stretch(struct sc_screen *screen,
                                 const SDL_FRect *geometry,
                                 float intensity, float alpha);
static void
sc_screen_note_display_ready_raw_frame(struct sc_screen *screen);
static bool
sc_screen_try_release_resize_hold(struct sc_screen *screen);

static bool
sc_screen_should_hold_resize(struct sc_screen *screen) {
    // Keep the last uploaded texture frozen while Android catches up. Incoming
    // frames stay on the CPU side and cannot pollute the blurred resize image.
    return screen->window_shown
        && screen->flex_display
        && screen->transient_stretch
        && screen->tex.texture;
}

static Uint32
sc_screen_resize_quiet_remaining_ms(struct sc_screen *screen, sc_tick now) {
    if (!screen->last_resize_event_tick) {
        return 0;
    }

    sc_tick elapsed = now - screen->last_resize_event_tick;
    if (elapsed >= FLEX_DISPLAY_RESIZE_QUIET_DELAY) {
        return 0;
    }

    Uint32 remaining_ms =
        SC_TICK_TO_MS(FLEX_DISPLAY_RESIZE_QUIET_DELAY - elapsed);
    return remaining_ms ? remaining_ms : 1;
}

static bool
sc_screen_compute_raw_frame_source_rect(struct sc_size frame_size,
                                        struct sc_size source_size,
                                        SDL_FRect *rect) {
    if (!frame_size.width || !frame_size.height
            || !source_size.width || !source_size.height) {
        return false;
    }

    float frame_ar = (float) frame_size.width / frame_size.height;
    float source_ar = (float) source_size.width / source_size.height;

    rect->x = 0;
    rect->y = 0;
    rect->w = frame_size.width;
    rect->h = frame_size.height;
    if (source_ar > frame_ar) {
        rect->h = rect->w / source_ar;
        rect->y = (frame_size.height - rect->h) / 2.f;
    } else if (source_ar < frame_ar) {
        rect->w = rect->h * source_ar;
        rect->x = (frame_size.width - rect->w) / 2.f;
    }

    return rect->w > 0 && rect->h > 0;
}

static bool
sc_screen_render_texture(struct sc_screen *screen, const SDL_FRect *geometry) {
    SDL_Renderer *renderer = screen->renderer;
    SDL_Texture *texture = screen->tex.texture;
    enum sc_orientation orientation = screen->orientation;
    SDL_FRect srcrect;
    const SDL_FRect *src = NULL;

    if (screen->raw_frame_source_open
            && screen->flex_display
            && screen->frame_size.width
            && screen->frame_size.height) {
        struct sc_size source_size = screen->transient_stretch
                                   ? screen->transient_stretch_source_size
                                   : screen->last_requested_display_size;
        if (!source_size.width || !source_size.height) {
            source_size = screen->last_requested_display_size;
        }

        if (sc_screen_compute_raw_frame_source_rect(screen->frame_size,
                                                   source_size, &srcrect)) {
            src = &srcrect;
        }
    }

    if (orientation == SC_ORIENTATION_0) {
        return SDL_RenderTexture(renderer, texture, src, geometry);
    }

    unsigned cw_rotation = sc_orientation_get_rotation(orientation);
    double angle = 90 * cw_rotation;

    const SDL_FRect *dstrect = NULL;
    SDL_FRect rect;
    if (sc_orientation_is_swap(orientation)) {
        rect.x = geometry->x + (geometry->w - geometry->h) / 2.f;
        rect.y = geometry->y + (geometry->h - geometry->w) / 2.f;
        rect.w = geometry->h;
        rect.h = geometry->w;
        dstrect = &rect;
    } else {
        dstrect = geometry;
    }

    SDL_FlipMode flip = sc_orientation_is_mirror(orientation)
                      ? SDL_FLIP_HORIZONTAL : 0;

    return SDL_RenderTextureRotated(renderer, texture, src, dstrect, angle,
                                    NULL, flip);
}

static bool
sc_screen_render_texture_with_alpha(struct sc_screen *screen,
                                    const SDL_FRect *geometry, float alpha) {
    if (alpha <= 0.0f) {
        return true;
    }
    if (alpha >= 1.0f) {
        return sc_screen_render_texture(screen, geometry);
    }

    SDL_Texture *texture = screen->tex.texture;
    SDL_BlendMode previous_blend_mode = SDL_BLENDMODE_BLEND;
    bool got_blend_mode = SDL_GetTextureBlendMode(texture,
                                                  &previous_blend_mode);
    Uint8 previous_alpha = 255;
    bool got_alpha = SDL_GetTextureAlphaMod(texture, &previous_alpha);

    bool ok = SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_BLEND);
    Uint8 texture_alpha = (Uint8) (255.0f * alpha + 0.5f);
    ok &= SDL_SetTextureAlphaMod(texture, texture_alpha);
    if (ok) {
        ok &= sc_screen_render_texture(screen, geometry);
    }

    if (got_alpha) {
        SDL_SetTextureAlphaMod(texture, previous_alpha);
    } else {
        SDL_SetTextureAlphaMod(texture, 255);
    }
    if (got_blend_mode) {
        SDL_SetTextureBlendMode(texture, previous_blend_mode);
    } else {
        SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_NONE);
    }

    return ok;
}

static void
sc_screen_destroy_resize_preview(struct sc_screen *screen) {
    if (screen->resize_preview_texture) {
        SDL_DestroyTexture(screen->resize_preview_texture);
        screen->resize_preview_texture = NULL;
    }
    screen->resize_preview_size.width = 0;
    screen->resize_preview_size.height = 0;
}

enum sc_resize_preview_mode {
    SC_RESIZE_PREVIEW_CONTENT,
    SC_RESIZE_PREVIEW_WINDOW,
};

static struct sc_size
sc_screen_get_resize_preview_source_size(struct sc_screen *screen) {
    if (sc_size_is_valid(screen->last_requested_display_size)) {
        return screen->last_requested_display_size;
    }
    return screen->frame_size;
}

static void
sc_screen_set_resize_preview_source_fallback(struct sc_screen *screen) {
    screen->transient_stretch_source_size =
        sc_screen_get_resize_preview_source_size(screen);
}

static bool
sc_screen_capture_preview(struct sc_screen *screen, struct sc_size preview_size,
                          struct sc_size source_size, const char *label) {
    sc_screen_destroy_resize_preview(screen);

    if (!screen->tex.texture
            || !sc_size_is_valid(preview_size)
            || !sc_size_is_valid(source_size)) {
        return false;
    }

    SDL_Texture *preview =
        SDL_CreateTexture(screen->renderer, SDL_PIXELFORMAT_RGBA8888,
                          SDL_TEXTUREACCESS_TARGET,
                          preview_size.width, preview_size.height);
    if (!preview) {
        LOGW("Could not create %s preview texture: %s",
             label, SDL_GetError());
        return false;
    }

    SDL_SetTextureScaleMode(preview, SDL_SCALEMODE_LINEAR);
    SDL_SetTextureBlendMode(preview, SDL_BLENDMODE_BLEND);

    SDL_Texture *previous_target = SDL_GetRenderTarget(screen->renderer);
    if (!SDL_SetRenderTarget(screen->renderer, preview)) {
        LOGW("Could not set %s preview target: %s", label, SDL_GetError());
        SDL_DestroyTexture(preview);
        return false;
    }

    SDL_SetRenderDrawColor(screen->renderer, 0, 0, 0, 0xff);
    sc_sdl_render_clear(screen->renderer);

    SDL_FRect dst = {
        .x = 0,
        .y = 0,
        .w = preview_size.width,
        .h = preview_size.height,
    };
    bool ok = sc_screen_render_texture(screen, &dst);

    if (!SDL_SetRenderTarget(screen->renderer, previous_target)) {
        LOGW("Could not restore render target: %s", SDL_GetError());
    }

    if (!ok) {
        SDL_DestroyTexture(preview);
        return false;
    }

    screen->resize_preview_texture = preview;
    screen->resize_preview_size = preview_size;
    screen->transient_stretch_source_size = source_size;
    return true;
}

static bool
sc_screen_capture_resize_preview(struct sc_screen *screen) {
    struct sc_size source_size = {0};
    if (sc_size_is_valid(screen->frame_size)) {
        source_size = sc_screen_get_resize_preview_source_size(screen);
    }

    struct sc_size preview_size =
        get_oriented_size(source_size, screen->orientation);
    return sc_screen_capture_preview(screen, preview_size, source_size,
                                     "resize");
}

static bool
sc_screen_capture_window_preview(struct sc_screen *screen) {
    struct sc_size preview_size =
        sc_sdl_get_render_output_size(screen->renderer);
    struct sc_size source_size =
        sc_screen_get_resize_preview_source_size(screen);

    return sc_screen_capture_preview(screen, preview_size, source_size,
                                     "window restore");
}

static void
sc_screen_begin_resize_hold(struct sc_screen *screen, sc_tick now,
                            enum sc_resize_preview_mode preview_mode) {
    if (!screen->transient_stretch) {
        screen->blur_fade_in_start_tick = now;
        bool captured = preview_mode == SC_RESIZE_PREVIEW_WINDOW
                      ? sc_screen_capture_window_preview(screen)
                      : sc_screen_capture_resize_preview(screen);
        if (!captured) {
            sc_screen_set_resize_preview_source_fallback(screen);
        }
        sc_screen_start_blur_animation_timer(screen);
    }

    screen->transient_stretch = true;
    screen->last_resize_event_tick = now;
    sc_screen_schedule_resize_settle(screen);
}

static void
sc_screen_start_restore_stretch(struct sc_screen *screen) {
    if (!screen->window_shown || !screen->flex_display || !screen->tex.texture) {
        return;
    }

    if (screen->blur_fade_start_tick) {
        sc_screen_stop_blur_fade(screen);
    }

    sc_screen_begin_resize_hold(screen, sc_tick_now(),
                                SC_RESIZE_PREVIEW_WINDOW);
    screen->display_ready = false;
    screen->display_ready_tick = 0;
    screen->display_ready_raw_frame = false;
}

// Renders the current texture with low-alpha ghost copies overlaid at small,
// jittered offsets. During resize, the texture is stretched to the window and
// blurred in; after release, the newly uploaded texture is blurred out to full
// quality.
static bool
sc_screen_render_blurred_stretch(struct sc_screen *screen,
                                 const SDL_FRect *geometry,
                                 float intensity, float alpha) {
    bool ok = sc_screen_render_texture_with_alpha(screen, geometry, alpha);

    if (intensity <= 0.0f || alpha <= 0.0f) {
        return ok;
    }

    SDL_Texture *texture = screen->tex.texture;
    SDL_BlendMode previous_blend_mode = SDL_BLENDMODE_BLEND;
    bool got_blend_mode = SDL_GetTextureBlendMode(texture,
                                                  &previous_blend_mode);
    Uint8 previous_alpha = 255;
    bool got_alpha = SDL_GetTextureAlphaMod(texture, &previous_alpha);

    int scaled = (int) (FLEX_DISPLAY_BLUR_ALPHA * intensity * alpha + 0.5f);
    if (scaled < 1) {
        scaled = 1;
    }
    Uint8 ghost_alpha = (Uint8) scaled;

    if (!SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_BLEND)
            || !SDL_SetTextureAlphaMod(texture, ghost_alpha)) {
        return ok;
    }

    static const SDL_FPoint offsets[] = {
        {-0.6f, -0.9f}, { 0.4f, -1.0f}, { 1.0f, -0.4f},
        { 0.9f,  0.6f}, { 0.0f,  1.1f}, {-1.0f,  0.5f},
        {-1.1f, -0.2f}, {-0.2f, -1.3f},

        {-1.8f, -1.5f}, {-0.8f, -2.1f}, { 0.6f, -2.2f},
        { 1.7f, -1.4f}, { 2.2f, -0.3f}, { 2.0f,  1.0f},
        { 0.9f,  2.0f}, {-0.4f,  2.3f}, {-1.6f,  1.6f},
        {-2.2f,  0.4f}, {-2.0f, -0.8f}, {-1.1f, -2.4f},

        {-3.3f, -2.2f}, {-2.1f, -3.0f}, {-0.7f, -3.5f},
        { 0.9f, -3.4f}, { 2.4f, -2.5f}, { 3.3f, -1.2f},
        { 3.5f,  0.5f}, { 2.8f,  1.9f}, { 1.4f,  3.1f},
        {-0.2f,  3.6f}, {-1.8f,  3.0f}, {-3.0f,  1.9f},
        {-3.6f,  0.3f}, {-3.2f, -1.1f}, {-2.6f, -2.7f},
        { 0.1f, -4.0f},

        {-4.8f, -3.0f}, {-3.4f, -4.3f}, {-1.7f, -5.0f},
        { 0.3f, -5.3f}, { 2.2f, -4.7f}, { 3.9f, -3.5f},
        { 5.0f, -1.7f}, { 5.3f,  0.3f}, { 4.6f,  2.2f},
        { 3.2f,  3.9f}, { 1.3f,  5.1f}, {-0.7f,  5.3f},
        {-2.6f,  4.5f}, {-4.2f,  3.2f}, {-5.1f,  1.3f},
        {-5.2f, -0.7f}, {-4.4f, -2.5f}, {-2.8f, -4.6f},
    };

    float step = FLEX_DISPLAY_BLUR_STEP * intensity;
    for (size_t i = 0; i < ARRAY_LEN(offsets); ++i) {
        SDL_FRect rect = *geometry;
        rect.x += offsets[i].x * step;
        rect.y += offsets[i].y * step;
        ok &= sc_screen_render_texture(screen, &rect);
    }

    if (got_alpha) {
        SDL_SetTextureAlphaMod(texture, previous_alpha);
    } else {
        SDL_SetTextureAlphaMod(texture, 255);
    }
    if (got_blend_mode) {
        SDL_SetTextureBlendMode(texture, previous_blend_mode);
    } else {
        SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_NONE);
    }

    return ok;
}

static bool
sc_screen_render_resize_preview(struct sc_screen *screen,
                                const SDL_FRect *geometry,
                                float alpha,
                                float intensity) {
    SDL_Texture *texture = screen->resize_preview_texture;
    if (!texture || alpha <= 0.0f) {
        return true;
    }

    if (alpha > 1.0f) {
        alpha = 1.0f;
    }
    if (intensity < 0.0f) {
        intensity = 0.0f;
    } else if (intensity > 1.0f) {
        intensity = 1.0f;
    }

    SDL_BlendMode previous_blend_mode = SDL_BLENDMODE_BLEND;
    bool got_blend_mode = SDL_GetTextureBlendMode(texture,
                                                  &previous_blend_mode);
    Uint8 previous_alpha = 255;
    bool got_alpha = SDL_GetTextureAlphaMod(texture, &previous_alpha);

    bool ok = SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_BLEND);
    Uint8 base_alpha = (Uint8) (255.0f * alpha + 0.5f);
    ok &= SDL_SetTextureAlphaMod(texture, base_alpha);
    if (ok) {
        ok &= SDL_RenderTexture(screen->renderer, texture, NULL, geometry);
    }

    if (ok && intensity > 0.0f) {
        int scaled =
            (int) (FLEX_DISPLAY_BLUR_ALPHA * intensity * alpha + 0.5f);
        if (scaled < 1) {
            scaled = 1;
        }
        Uint8 ghost_alpha = (Uint8) scaled;

        ok &= SDL_SetTextureAlphaMod(texture, ghost_alpha);

        static const SDL_FPoint offsets[] = {
            {-0.6f, -0.9f}, { 0.4f, -1.0f}, { 1.0f, -0.4f},
            { 0.9f,  0.6f}, { 0.0f,  1.1f}, {-1.0f,  0.5f},
            {-1.1f, -0.2f}, {-0.2f, -1.3f},

            {-1.8f, -1.5f}, {-0.8f, -2.1f}, { 0.6f, -2.2f},
            { 1.7f, -1.4f}, { 2.2f, -0.3f}, { 2.0f,  1.0f},
            { 0.9f,  2.0f}, {-0.4f,  2.3f}, {-1.6f,  1.6f},
            {-2.2f,  0.4f}, {-2.0f, -0.8f}, {-1.1f, -2.4f},

            {-3.3f, -2.2f}, {-2.1f, -3.0f}, {-0.7f, -3.5f},
            { 0.9f, -3.4f}, { 2.4f, -2.5f}, { 3.3f, -1.2f},
            { 3.5f,  0.5f}, { 2.8f,  1.9f}, { 1.4f,  3.1f},
            {-0.2f,  3.6f}, {-1.8f,  3.0f}, {-3.0f,  1.9f},
            {-3.6f,  0.3f}, {-3.2f, -1.1f}, {-2.6f, -2.7f},
            { 0.1f, -4.0f},

            {-4.8f, -3.0f}, {-3.4f, -4.3f}, {-1.7f, -5.0f},
            { 0.3f, -5.3f}, { 2.2f, -4.7f}, { 3.9f, -3.5f},
            { 5.0f, -1.7f}, { 5.3f,  0.3f}, { 4.6f,  2.2f},
            { 3.2f,  3.9f}, { 1.3f,  5.1f}, {-0.7f,  5.3f},
            {-2.6f,  4.5f}, {-4.2f,  3.2f}, {-5.1f,  1.3f},
            {-5.2f, -0.7f}, {-4.4f, -2.5f}, {-2.8f, -4.6f},
        };

        float step = FLEX_DISPLAY_BLUR_STEP * intensity;
        for (size_t i = 0; i < ARRAY_LEN(offsets); ++i) {
            SDL_FRect rect = *geometry;
            rect.x += offsets[i].x * step;
            rect.y += offsets[i].y * step;
            ok &= SDL_RenderTexture(screen->renderer, texture, NULL, &rect);
        }
    }

    if (got_alpha) {
        SDL_SetTextureAlphaMod(texture, previous_alpha);
    } else {
        SDL_SetTextureAlphaMod(texture, 255);
    }
    if (got_blend_mode) {
        SDL_SetTextureBlendMode(texture, previous_blend_mode);
    } else {
        SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_NONE);
    }

    return ok;
}

static void
sc_screen_render_window_border(struct sc_screen *screen) {
    const int border_thickness = 2;

    uint64_t flags = SDL_GetWindowFlags(screen->window);
    bool borderless = flags & SDL_WINDOW_BORDERLESS;
    bool fullscreen = flags & SDL_WINDOW_FULLSCREEN;
    if (!borderless || fullscreen) {
        return;
    }

    struct sc_size render_size =
        sc_sdl_get_render_output_size(screen->renderer);
    if (render_size.width < 2 * border_thickness
            || render_size.height < 2 * border_thickness) {
        return;
    }

    SDL_SetRenderDrawColor(screen->renderer, 0x33, 0x33, 0x33, 0xff);
    const float t = border_thickness;
    SDL_FRect top = {
        .x = 0,
        .y = 0,
        .w = render_size.width,
        .h = t,
    };
    SDL_FRect bottom = {
        .x = 0,
        .y = render_size.height - t,
        .w = render_size.width,
        .h = t,
    };
    SDL_FRect left = {
        .x = 0,
        .y = t,
        .w = t,
        .h = render_size.height - 2 * t,
    };
    SDL_FRect right = {
        .x = render_size.width - t,
        .y = t,
        .w = t,
        .h = render_size.height - 2 * t,
    };
    SDL_RenderFillRect(screen->renderer, &top);
    SDL_RenderFillRect(screen->renderer, &bottom);
    SDL_RenderFillRect(screen->renderer, &left);
    SDL_RenderFillRect(screen->renderer, &right);
}

// render the texture to the renderer
//
// Hold the prepared window black until flex_display has settled and
// SC_WINDOW_FADE_IN_HOLD has elapsed, then fade the rendered content in over
// SC_WINDOW_FADE_IN_DURATION. The fade starts on the first render after that
// hold so a busy compositor cannot skip the visible ramp.
static float
sc_screen_get_window_fade_alpha(struct sc_screen *screen) {
    if (!screen->window_fade_in_show_tick) {
        return 1.0f;
    }
    sc_tick now = sc_tick_now();

    if (!screen->window_fade_in_start_tick) {
        sc_tick held = now - screen->window_fade_in_show_tick;
        bool min_hold_elapsed = held >= SC_WINDOW_FADE_IN_HOLD;
        bool flex_settled = !screen->flex_display || !screen->transient_stretch;
        bool max_hold_elapsed = held >= SC_WINDOW_FADE_IN_MAX_HOLD;
        if ((!min_hold_elapsed || !flex_settled) && !max_hold_elapsed) {
            return 0.0f;
        }
        screen->window_fade_in_start_tick = now;
    }

    sc_tick fade_elapsed = now - screen->window_fade_in_start_tick;
    if (!fade_elapsed) {
        return 0.0f;
    }

    if (fade_elapsed >= SC_WINDOW_FADE_IN_DURATION) {
        screen->window_fade_in_show_tick = 0;
        screen->window_fade_in_start_tick = 0;
        return 1.0f;
    }
    return (float) fade_elapsed / (float) SC_WINDOW_FADE_IN_DURATION;
}

// Set the update_content_rect flag if the window or content size may have
// changed, so that the content rectangle is recomputed
static void
sc_screen_render(struct sc_screen *screen, bool update_content_rect) {
    assert(screen->window_shown);

    if (update_content_rect || screen->transient_stretch) {
        sc_screen_update_content_rect(screen);
    }

    SDL_Renderer *renderer = screen->renderer;
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0xff);
    sc_sdl_render_clear(renderer);

    float startup_alpha = sc_screen_get_window_fade_alpha(screen);

    bool ok = false;
    SDL_Texture *texture = screen->tex.texture;
    if (!texture) {
        // Draw a dark 10x10 square in the top-right corner to distinguish a
        // black frame from the absence of a frame
        struct sc_size render_size = sc_sdl_get_render_output_size(renderer);
        SDL_SetRenderDrawColor(renderer, 0, 0, 0x33, 0xff);
        SDL_FRect rect = {
            .x = render_size.width - 20,
            .y = 10,
            .w = 10,
            .h = 10,
        };
        SDL_RenderFillRect(renderer, &rect);
        goto end;
    }

    // During resize, draw a captured preview texture if available. Once the
    // live frame catches up, the preview fades out over the final frame so
    // the content transition is a crossfade instead of a hard swap.
    SDL_FRect *geometry = &screen->rect;
    if (screen->flex_display && screen->transient_stretch
            && screen->resize_preview_texture) {
        ok = sc_screen_render_resize_preview(
                screen, geometry, startup_alpha,
                sc_screen_blur_fade_in_intensity(screen));
    } else {
        ok = sc_screen_render_texture_with_alpha(screen, geometry,
                                                 startup_alpha);
        if (ok && screen->flex_display && screen->blur_fade_start_tick
                && screen->resize_preview_texture) {
            float intensity = sc_screen_blur_intensity(screen);
            if (intensity <= 0.0f) {
                sc_screen_stop_blur_fade(screen);
            } else {
                ok &= sc_screen_render_resize_preview(screen, geometry,
                                                      intensity * startup_alpha,
                                                      intensity);
            }
        } else if (screen->flex_display
                && (screen->transient_stretch
                    || screen->blur_fade_start_tick)) {
            float intensity = screen->transient_stretch
                            ? sc_screen_blur_fade_in_intensity(screen)
                            : sc_screen_blur_intensity(screen);
            if (intensity <= 0.0f) {
                if (screen->blur_fade_start_tick) {
                    sc_screen_stop_blur_fade(screen);
                }
            } else {
                ok &= sc_screen_render_blurred_stretch(screen, geometry,
                                                       intensity,
                                                       startup_alpha);
            }
        }
    }

    if (!ok) {
        LOGE("Could not render texture: %s", SDL_GetError());
    }

end:
    if (startup_alpha >= 1.0f) {
        sc_screen_render_window_border(screen);
    }
    sc_sdl_render_present(renderer);
    if (screen->window_shown) {
        // Secondary backstop: some Wayland compositors swallow resize events.
        // SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED covers the primary DPI path;
        // this catches any residual misses. Returns immediately (O(1)) when
        // the window size hasn't changed since the last request.
        sc_screen_maybe_request_display_resize(screen, false);
    }
}

static unsigned
sc_screen_parse_cuttlefish_instance(const char *socket_path) {
    if (!socket_path) {
        return 1;
    }

    const char *p = socket_path;
    while ((p = strstr(p, "cvd-"))) {
        p += 4;
        char *end = NULL;
        unsigned long instance = strtoul(p, &end, 10);
        if (end != p && instance > 0 && instance <= 9999) {
            return (unsigned) instance;
        }
    }

    return 1;
}

static const char *
sc_screen_get_cvd_bin(void) {
    const char *cvd_bin = getenv("IKA_CVD_BIN");
    if (cvd_bin && *cvd_bin) {
        return cvd_bin;
    }

    return "/usr/lib/cuttlefish-common/bin/cvd";
}

static void
sc_screen_resize_cuttlefish_physical_display(struct sc_screen *screen,
                                             uint16_t width, uint16_t height) {
    if (!screen->cuttlefish_frames_socket) {
        return;
    }

    unsigned instance =
        sc_screen_parse_cuttlefish_instance(screen->cuttlefish_frames_socket);
    uint16_t dpi = screen->flex_display_dpi ? screen->flex_display_dpi : 320;

    char instance_arg[32];
    char display_id_arg[32];
    char display_arg[128];
    snprintf(instance_arg, sizeof(instance_arg), "--instance_num=%u", instance);
    snprintf(display_id_arg, sizeof(display_id_arg), "--display_id=%" PRIu32,
             screen->cuttlefish_display_id);
    snprintf(display_arg, sizeof(display_arg),
             "--display=width=%" PRIu16 ",height=%" PRIu16
             ",dpi=%" PRIu16 ",refresh_rate_hz=60",
             width, height, dpi);

    const char *const argv[] = {
        sc_screen_get_cvd_bin(),
        "display",
        "resize",
        instance_arg,
        display_id_arg,
        display_arg,
        NULL,
    };

    // Reap any still-running resize child before spawning a new one.
    if (screen->cuttlefish_resize_pid != SC_PROCESS_NONE) {
        sc_process_close(screen->cuttlefish_resize_pid);
        screen->cuttlefish_resize_pid = SC_PROCESS_NONE;
    }

    sc_pid pid;
    enum sc_process_result result =
        sc_process_execute(argv, &pid, SC_PROCESS_NO_STDOUT
                                      | SC_PROCESS_NO_STDERR);
    if (result != SC_PROCESS_SUCCESS) {
        LOGD("Could not execute Cuttlefish physical display resize");
        return;
    }

    // Don't block — let the resize command run concurrently with incoming
    // frames. The pid is reaped at the next resize call or in destroy().
    screen->cuttlefish_resize_pid = pid;
}

static void
sc_screen_maybe_request_display_resize(struct sc_screen *screen, bool force) {
    if (!screen->flex_display || screen->disconnected) {
        return;
    }
    if (!force && screen->transient_stretch) {
        return;
    }

    assert(!screen->camera);
    // For regular encoded display capture, keep the remote display at the
    // logical window size to avoid creating unnecessarily large encoder input.
    // For Direct Display/raw frames, request the renderer output size instead
    // so HiDPI desktop scaling does not upscale already-rendered text.
    struct sc_size resize_size = screen->resize_display_using_pixel_size
                               ? sc_sdl_get_render_output_size(screen->renderer)
                               : sc_sdl_get_window_size(screen->window);

    uint16_t width = resize_size.width;
    uint16_t height = resize_size.height;
    if (sc_orientation_is_swap(screen->orientation)) {
        uint16_t tmp = width;
        width = height;
        height = tmp;
    }

    // For encoded video the server rounds up to the codec's macroblock
    // alignment; pre-round down here so both sides agree. Raw-frame paths
    // (resize_display_using_pixel_size) have no encoder, so pass as-is.
    if (!screen->resize_display_using_pixel_size) {
        width &= ~7;
        height &= ~7;
    }
    if (!width || !height) {
        return;
    }

    sc_tick now = sc_tick_now();
    if (screen->last_requested_display_size.width == width
            && screen->last_requested_display_size.height == height) {
        if (screen->transient_stretch && !screen->display_ready) {
            screen->display_ready = true;
            screen->display_ready_tick = now;
            screen->display_ready_raw_frame = false;
        }
        return;
    }

    if (!force
            && screen->last_resize_request_tick
            && now - screen->last_resize_request_tick
                    < FLEX_DISPLAY_REQUEST_MIN_INTERVAL) {
        return;
    }

    screen->last_requested_display_size.width = width;
    screen->last_requested_display_size.height = height;
    screen->last_resize_request_tick = now;
    screen->display_ready = false;
    screen->display_ready_tick = 0;
    screen->display_ready_raw_frame = false;

    if (screen->resize_display_using_pixel_size) {
        sc_screen_resize_cuttlefish_physical_display(screen, width, height);
    }

    LOGV("resize_display(%" PRIu16 ", %" PRIu16 ")", width, height);
    sc_controller_resize_display(screen->controller, width, height);
}

static bool
sc_screen_snap_window_to_requested_pixel_size(struct sc_screen *screen) {
    if (!screen->resize_display_using_pixel_size || !is_windowed(screen)
            || !screen->last_requested_display_size.width
            || !screen->last_requested_display_size.height) {
        return false;
    }

    struct sc_size render_size =
        sc_sdl_get_render_output_size(screen->renderer);
    struct sc_size requested_size =
        get_oriented_size(screen->last_requested_display_size,
                          screen->orientation);

    if (render_size.width == requested_size.width
            && render_size.height == requested_size.height) {
        return false;
    }

    if (render_size.width < requested_size.width
            || render_size.height < requested_size.height) {
        return false;
    }

    struct sc_size window_size = sc_sdl_get_window_size(screen->window);
    struct sc_size target_size = {
        .width = (uint32_t) window_size.width * requested_size.width
               / render_size.width,
        .height = (uint32_t) window_size.height * requested_size.height
                / render_size.height,
    };

    struct sc_size min_window_size =
        sc_screen_get_min_window_size(screen->window);
    target_size.width = MAX(target_size.width, min_window_size.width);
    target_size.height = MAX(target_size.height, min_window_size.height);

    if (target_size.width == window_size.width
            && target_size.height == window_size.height) {
        return false;
    }

    struct sc_point position = sc_sdl_get_window_position(screen->window);
    struct sc_point target_position = {
        .x = position.x + (window_size.width - target_size.width) / 2,
        .y = position.y + (window_size.height - target_size.height) / 2,
    };

    sc_sdl_set_window_size(screen->window, target_size);
    sc_sdl_set_window_position(screen->window, target_position);
    LOGD("Snapped window to Direct Display pixel size: %ux%u",
         target_size.width, target_size.height);
    return true;
}

static void
sc_screen_on_resize(struct sc_screen *screen) {
    // This event can be triggered before the window is shown
    if (screen->window_shown) {
        sc_screen_note_raw_frame_resize_activity(screen);
        if (screen->flex_display) {
            // Cancel any in-flight fade-out before starting a new blur
            // fade-in for this resize.
            if (screen->blur_fade_start_tick) {
                sc_screen_stop_blur_fade(screen);
            }
            sc_screen_begin_resize_hold(screen, sc_tick_now(),
                                        SC_RESIZE_PREVIEW_CONTENT);
        }
        sc_screen_render(screen, true);
    }
}

static SDL_TimerID
sc_screen_take_resize_settle_timer_locked(struct sc_screen *screen) {
    SDL_TimerID timer = screen->resize_settle_timer;
    screen->resize_settle_timer = 0;
    return timer;
}

static void
sc_screen_schedule_resize_settle(struct sc_screen *screen) {
    Uint32 delay_ms = SC_TICK_TO_MS(FLEX_DISPLAY_RESIZE_QUIET_DELAY);
    if (!delay_ms) {
        delay_ms = 1;
    }

    sc_screen_schedule_resize_settle_after(screen, delay_ms);
}

static void
sc_screen_schedule_resize_settle_after(struct sc_screen *screen,
                                       Uint32 delay_ms) {
    if (!delay_ms) {
        delay_ms = 1;
    }

    SDL_TimerID old_timer;
    SDL_TimerID new_timer =
        SDL_AddTimer(delay_ms, sc_screen_resize_settle_timer, screen);

    sc_mutex_lock(&screen->mutex);
    old_timer = sc_screen_take_resize_settle_timer_locked(screen);
    screen->resize_settle_timer = new_timer;
    sc_mutex_unlock(&screen->mutex);

    if (old_timer) {
        SDL_RemoveTimer(old_timer);
    }
}

static Uint32 SDLCALL
sc_screen_resize_settle_timer(void *userdata, SDL_TimerID timerID,
                              Uint32 interval) {
    (void) interval;

    struct sc_screen *screen = userdata;
    bool push_event = false;

    sc_mutex_lock(&screen->mutex);
    if (screen->resize_settle_timer == timerID) {
        screen->resize_settle_timer = 0;
        push_event = true;
    }
    sc_mutex_unlock(&screen->mutex);

    if (push_event) {
        bool ok = sc_push_event(SC_EVENT_RESIZE_SETTLED);
        (void) ok; // ignore failure
    }

    return 0;
}

static float
sc_screen_blur_fade_in_intensity(struct sc_screen *screen) {
    if (!screen->blur_fade_in_start_tick) {
        return 1.0f;
    }
    sc_tick elapsed = sc_tick_now() - screen->blur_fade_in_start_tick;
    if (elapsed >= FLEX_DISPLAY_BLUR_FADE_IN_DURATION) {
        return 1.0f;
    }
    float progress = (float) elapsed
                   / (float) FLEX_DISPLAY_BLUR_FADE_IN_DURATION;
    return sc_screen_smoothstep(progress);
}

static float
sc_screen_blur_intensity(struct sc_screen *screen) {
    if (!screen->blur_fade_start_tick) {
        return 0.0f;
    }
    sc_tick elapsed = sc_tick_now() - screen->blur_fade_start_tick;
    if (elapsed < FLEX_DISPLAY_PREVIEW_REVEAL_DELAY) {
        return screen->blur_fade_start_intensity;
    }

    elapsed -= FLEX_DISPLAY_PREVIEW_REVEAL_DELAY;
    if (elapsed >= FLEX_DISPLAY_BLUR_FADE_OUT_DURATION) {
        return 0.0f;
    }
    float progress = (float) elapsed
                   / (float) FLEX_DISPLAY_BLUR_FADE_OUT_DURATION;
    float fade = 1.0f - sc_screen_smoothstep(progress);
    return screen->blur_fade_start_intensity * fade;
}

static Uint32 SDLCALL
sc_screen_blur_fade_timer(void *userdata, SDL_TimerID timerID,
                          Uint32 interval) {
    struct sc_screen *screen = userdata;
    bool push_event = false;
    bool keep_firing = false;

    sc_mutex_lock(&screen->mutex);
    if (screen->blur_fade_timer == timerID) {
        if (screen->blur_fade_start_tick) {
            push_event = true;
            keep_firing = true;
        } else if (screen->transient_stretch
                && screen->blur_fade_in_start_tick) {
            push_event = true;
            keep_firing = sc_tick_now() - screen->blur_fade_in_start_tick
                        < FLEX_DISPLAY_BLUR_FADE_IN_DURATION;
        }
        if (screen->window_fade_in_show_tick) {
            push_event = true;
            keep_firing = true;
        }
    }
    sc_mutex_unlock(&screen->mutex);

    if (push_event) {
        bool ok = sc_push_event(SC_EVENT_BLUR_FADE_TICK);
        (void) ok;
        if (keep_firing) {
            return interval;
        }
    }

    sc_mutex_lock(&screen->mutex);
    if (screen->blur_fade_timer == timerID) {
        screen->blur_fade_timer = 0;
    }
    sc_mutex_unlock(&screen->mutex);
    return 0;
}

static void
sc_screen_stop_blur_fade(struct sc_screen *screen) {
    SDL_TimerID old_timer;

    screen->blur_fade_start_tick = 0;
    screen->blur_fade_start_intensity = 0.0f;

    if (screen->window_fade_in_show_tick) {
        return;
    }

    sc_mutex_lock(&screen->mutex);
    old_timer = screen->blur_fade_timer;
    screen->blur_fade_timer = 0;
    sc_mutex_unlock(&screen->mutex);

    if (old_timer) {
        SDL_RemoveTimer(old_timer);
    }
}

static void
sc_screen_start_blur_animation_timer(struct sc_screen *screen) {
    SDL_TimerID new_timer = SDL_AddTimer(FLEX_DISPLAY_BLUR_FADE_INTERVAL_MS,
                                         sc_screen_blur_fade_timer, screen);
    SDL_TimerID old_timer;
    sc_mutex_lock(&screen->mutex);
    old_timer = screen->blur_fade_timer;
    screen->blur_fade_timer = new_timer;
    sc_mutex_unlock(&screen->mutex);

    if (old_timer) {
        SDL_RemoveTimer(old_timer);
    }
}

static void
sc_screen_start_blur_fade(struct sc_screen *screen) {
    if (!screen->flex_display || screen->blur_fade_start_tick) {
        return;
    }
    screen->blur_fade_start_intensity =
        sc_screen_blur_fade_in_intensity(screen);
    screen->blur_fade_in_start_tick = 0;
    screen->blur_fade_start_tick = sc_tick_now();
    sc_screen_start_blur_animation_timer(screen);
}

#if defined(__APPLE__) || defined(_WIN32)
# define CONTINUOUS_RESIZING_WORKAROUND
#endif

#ifdef CONTINUOUS_RESIZING_WORKAROUND
// On Windows and MacOS, resizing blocks the event loop, so resizing events are
// not triggered. As a workaround, handle them in an event handler.
//
// <https://bugzilla.libsdl.org/show_bug.cgi?id=2077>
// <https://stackoverflow.com/a/40693139/1987178>
static bool
event_watcher(void *data, SDL_Event *event) {
    struct sc_screen *screen = data;
    assert(screen->video);

    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
            || event->type == SDL_EVENT_WINDOW_RESIZED) {
        // In practice, it seems to always be called from the same thread in
        // that specific case. Anyway, it's just a workaround.
        sc_screen_on_resize(screen);
    }

    return true;
}
#endif

static bool
sc_screen_frame_sink_open(struct sc_frame_sink *sink,
                          const AVCodecContext *ctx,
                          const struct sc_stream_session *session) {
    assert(ctx->pix_fmt == AV_PIX_FMT_YUV420P);

    struct sc_screen *screen = DOWNCAST(sink);

    if (ctx->width <= 0 || ctx->width > 0xFFFF
            || ctx->height <= 0 || ctx->height > 0xFFFF) {
        LOGE("Invalid video size: %dx%d", ctx->width, ctx->height);
        return false;
    }

    // content_size can be written from this thread, because it is never read
    // from the main thread before handling SC_EVENT_OPEN_WINDOW (which acts as
    // a synchronization point) when video is enabled
    screen->frame_size.width = session->video.width;
    screen->frame_size.height = session->video.height;
    screen->content_size = get_oriented_size(screen->frame_size,
                                             screen->orientation);

    screen->current_session = *session;

    bool ok = sc_push_event(SC_EVENT_OPEN_WINDOW);
    if (!ok) {
        return false;
    }

#ifndef NDEBUG
    screen->open = true;
#endif

    // nothing to do, the screen is already open on the main thread
    return true;
}

static void
sc_screen_frame_sink_close(struct sc_frame_sink *sink) {
    struct sc_screen *screen = DOWNCAST(sink);
    (void) screen;
#ifndef NDEBUG
    screen->open = false;
#endif

    // nothing to do, the screen lifecycle is not managed by the frame producer
}

static bool
sc_screen_frame_sink_push(struct sc_frame_sink *sink, const AVFrame *frame) {
    struct sc_screen *screen = DOWNCAST(sink);
    assert(screen->video);

    sc_mutex_lock(&screen->mutex);
    bool previous_skipped = sc_frame_buffer_has_frame(&screen->fb);
    bool ok = sc_frame_buffer_push(&screen->fb, frame);
    screen->prevent_auto_resize = screen->current_session.video.client_resized;
    sc_mutex_unlock(&screen->mutex);
    if (!ok) {
        return false;
    }

    if (previous_skipped) {
        sc_fps_counter_add_skipped_frame(&screen->fps_counter);
        // The SC_EVENT_NEW_FRAME triggered for the previous frame will consume
        // this new frame instead
    } else {
        // Post the event on the UI thread
        bool ok = sc_push_event(SC_EVENT_NEW_FRAME);
        if (!ok) {
            return false;
        }
    }

    return true;
}

static bool
sc_screen_frame_sink_push_session(struct sc_frame_sink *sink,
                                  const struct sc_stream_session *session) {
    struct sc_screen *screen = DOWNCAST(sink);
    screen->current_session = *session;
    return true;
}

static void
sc_screen_recycle_raw_frame_buffer_locked(struct sc_screen *screen,
                                          uint8_t *pixels, size_t capacity) {
    if (!pixels || !capacity) {
        free(pixels);
        return;
    }

    for (size_t i = 0; i < SC_RAW_FRAME_BUFFER_POOL_SIZE; ++i) {
        size_t index = (screen->raw_frame_buffer_next + i)
                     % SC_RAW_FRAME_BUFFER_POOL_SIZE;
        struct sc_raw_frame_buffer *buffer =
            &screen->raw_frame_buffer_pool[index];
        if (!buffer->pixels) {
            buffer->pixels = pixels;
            buffer->capacity = capacity;
            screen->raw_frame_buffer_next =
                (index + 1) % SC_RAW_FRAME_BUFFER_POOL_SIZE;
            return;
        }
    }

    size_t smallest = 0;
    for (size_t i = 1; i < SC_RAW_FRAME_BUFFER_POOL_SIZE; ++i) {
        if (screen->raw_frame_buffer_pool[i].capacity
                < screen->raw_frame_buffer_pool[smallest].capacity) {
            smallest = i;
        }
    }

    if (capacity > screen->raw_frame_buffer_pool[smallest].capacity) {
        free(screen->raw_frame_buffer_pool[smallest].pixels);
        screen->raw_frame_buffer_pool[smallest].pixels = pixels;
        screen->raw_frame_buffer_pool[smallest].capacity = capacity;
        screen->raw_frame_buffer_next =
            (smallest + 1) % SC_RAW_FRAME_BUFFER_POOL_SIZE;
    } else {
        free(pixels);
    }
}

uint8_t *
sc_screen_alloc_raw_frame_buffer(struct sc_screen *screen, size_t size) {
    if (!size) {
        return NULL;
    }

    size_t best = SC_RAW_FRAME_BUFFER_POOL_SIZE;
    sc_mutex_lock(&screen->mutex);
    for (size_t i = 0; i < SC_RAW_FRAME_BUFFER_POOL_SIZE; ++i) {
        struct sc_raw_frame_buffer *buffer =
            &screen->raw_frame_buffer_pool[i];
        if (buffer->pixels && buffer->capacity >= size
                && (best == SC_RAW_FRAME_BUFFER_POOL_SIZE
                    || buffer->capacity
                        < screen->raw_frame_buffer_pool[best].capacity)) {
            best = i;
        }
    }

    if (best != SC_RAW_FRAME_BUFFER_POOL_SIZE) {
        struct sc_raw_frame_buffer *buffer =
            &screen->raw_frame_buffer_pool[best];
        uint8_t *pixels = buffer->pixels;
        buffer->pixels = NULL;
        buffer->capacity = 0;
        sc_mutex_unlock(&screen->mutex);
        return pixels;
    }
    sc_mutex_unlock(&screen->mutex);

    return malloc(size);
}

void
sc_screen_recycle_raw_frame_buffer(struct sc_screen *screen, uint8_t *pixels,
                                   size_t capacity) {
    sc_mutex_lock(&screen->mutex);
    sc_screen_recycle_raw_frame_buffer_locked(screen, pixels, capacity);
    sc_mutex_unlock(&screen->mutex);
}

static void
sc_screen_raw_frame_clear(struct sc_screen *screen, bool pending) {
    if (pending) {
        if (screen->pending_raw_frame.owns_pixels) {
            sc_screen_recycle_raw_frame_buffer_locked(
                screen, screen->pending_raw_frame.pixels,
                screen->pending_raw_frame.size_bytes);
        }
#ifndef _WIN32
        if (screen->pending_raw_frame.dmabuf_fd >= 0) {
            close(screen->pending_raw_frame.dmabuf_fd);
        }
#endif
        memset(&screen->pending_raw_frame, 0, sizeof(screen->pending_raw_frame));
        screen->pending_raw_frame.dmabuf_fd = -1;
        screen->pending_raw_frame_available = false;
    } else {
        if (screen->raw_frame.owns_pixels) {
            sc_screen_recycle_raw_frame_buffer_locked(
                screen, screen->raw_frame.pixels, screen->raw_frame.size_bytes);
        }
#ifndef _WIN32
        if (screen->raw_frame.dmabuf_fd >= 0) {
            close(screen->raw_frame.dmabuf_fd);
        }
#endif
        memset(&screen->raw_frame, 0, sizeof(screen->raw_frame));
        screen->raw_frame.dmabuf_fd = -1;
    }
}

static void
sc_screen_raw_frame_cancel_pending_push(struct sc_screen *screen,
                                        bool close_source) {
    sc_mutex_lock(&screen->mutex);
    sc_screen_raw_frame_clear(screen, true);
    screen->raw_frame_event_pending = false;
    SDL_TimerID timer =
        sc_screen_take_raw_frame_refresh_timer_locked(screen);
    if (close_source) {
        screen->raw_frame_source_open = false;
#ifndef NDEBUG
        screen->open = false;
#endif
    }
    sc_mutex_unlock(&screen->mutex);
    if (timer) {
        SDL_RemoveTimer(timer);
    }
}

static bool
sc_screen_should_throttle_raw_frame_locked(struct sc_screen *screen,
                                           sc_tick now) {
    if (!screen->raw_frame_source_open
            || !screen->last_raw_frame_render_tick
            || !screen->last_raw_frame_resize_tick) {
        return false;
    }

    bool resize_active = now - screen->last_raw_frame_resize_tick
            < RAW_FRAME_RESIZE_THROTTLE_WINDOW;
    if (!resize_active) {
        return false;
    }

    return now - screen->last_raw_frame_render_tick
            < RAW_FRAME_RESIZE_RENDER_INTERVAL;
}

static Uint32
sc_screen_raw_frame_throttle_delay_ms_locked(struct sc_screen *screen,
                                             sc_tick now) {
    sc_tick deadline =
        screen->last_raw_frame_render_tick
        + RAW_FRAME_RESIZE_RENDER_INTERVAL;
    sc_tick delay = deadline > now ? deadline - now : SC_TICK_FROM_MS(1);
    Uint32 delay_ms = SC_TICK_TO_MS(delay);
    return delay_ms ? delay_ms : 1;
}

static SDL_TimerID
sc_screen_take_raw_frame_refresh_timer_locked(struct sc_screen *screen) {
    SDL_TimerID timer = screen->raw_frame_refresh_timer;
    screen->raw_frame_refresh_timer = 0;
    return timer;
}

static void
sc_screen_schedule_raw_frame_refresh_locked(struct sc_screen *screen,
                                            sc_tick now) {
    if (screen->raw_frame_refresh_timer
            || !screen->pending_raw_frame_available
            || screen->raw_frame_event_pending) {
        return;
    }

    screen->raw_frame_refresh_timer =
        SDL_AddTimer(sc_screen_raw_frame_throttle_delay_ms_locked(screen, now),
                     sc_screen_raw_frame_refresh_timer, screen);
}

static SDL_TimerID
sc_screen_take_initial_window_show_timer_locked(struct sc_screen *screen) {
    SDL_TimerID timer = screen->initial_window_show_timer;
    screen->initial_window_show_timer = 0;
    return timer;
}

static Uint32 SDLCALL
sc_screen_initial_window_show_timer(void *userdata, SDL_TimerID timerID,
                                    Uint32 interval) {
    (void) interval;

    struct sc_screen *screen = userdata;
    bool push_open_window_event = false;

    sc_mutex_lock(&screen->mutex);
    if (screen->initial_window_show_timer == timerID) {
        screen->initial_window_show_timer = 0;
        push_open_window_event = screen->initial_window_show_deferred
                              && !screen->window_shown;
    }
    sc_mutex_unlock(&screen->mutex);

    if (push_open_window_event
            && !sc_push_event(SC_EVENT_INITIAL_WINDOW_SHOW_TIMEOUT)) {
        LOGW("Could not push initial window show timeout event");
    }

    return 0;
}

static void
sc_screen_schedule_initial_window_show_timer(struct sc_screen *screen) {
    sc_mutex_lock(&screen->mutex);
    if (screen->initial_window_show_timer) {
        sc_mutex_unlock(&screen->mutex);
        return;
    }

    screen->initial_window_show_timer =
        SDL_AddTimer(SC_TICK_TO_MS(FLEX_DISPLAY_INITIAL_SHOW_TIMEOUT),
                     sc_screen_initial_window_show_timer, screen);
    sc_mutex_unlock(&screen->mutex);
}

static Uint32 SDLCALL
sc_screen_raw_frame_refresh_timer(void *userdata, SDL_TimerID timerID,
                                  Uint32 interval) {
    (void) interval;

    struct sc_screen *screen = userdata;
    bool push_raw_frame_event = false;
    Uint32 next_interval = 0;

    sc_mutex_lock(&screen->mutex);
    if (screen->raw_frame_refresh_timer != timerID) {
        sc_mutex_unlock(&screen->mutex);
        return 0;
    }

    sc_tick now = sc_tick_now();
    if (!screen->raw_frame_source_open
            || !screen->pending_raw_frame_available
            || screen->raw_frame_event_pending) {
        screen->raw_frame_refresh_timer = 0;
    } else if (sc_screen_should_throttle_raw_frame_locked(screen, now)) {
        next_interval =
            sc_screen_raw_frame_throttle_delay_ms_locked(screen, now);
    } else {
        screen->raw_frame_refresh_timer = 0;
        screen->raw_frame_event_pending = true;
        push_raw_frame_event = true;
    }
    sc_mutex_unlock(&screen->mutex);

    if (push_raw_frame_event && !sc_push_event(SC_EVENT_NEW_RAW_FRAME)) {
        sc_screen_raw_frame_cancel_pending_push(screen, false);
    }

    return next_interval;
}

bool
sc_screen_push_raw_frame(struct sc_screen *screen, uint32_t display_number,
                         uint32_t width, uint32_t height, uint32_t fourcc,
                         SDL_PixelFormat format, uint32_t stride,
                         uint8_t *pixels, size_t size_bytes,
                         bool owns_pixels) {
    assert(screen->video);

    if (!width || width > 0xFFFF || !height || height > 0xFFFF
            || format == SDL_PIXELFORMAT_UNKNOWN || !stride || !pixels
            || !size_bytes) {
        LOGE("Invalid raw frame");
        if (owns_pixels) {
            sc_screen_recycle_raw_frame_buffer(screen, pixels, size_bytes);
        }
        return false;
    }

    bool open_window = false;
    bool previous_skipped;
    bool push_raw_frame_event = false;

    sc_mutex_lock(&screen->mutex);
    sc_tick now = sc_tick_now();
    bool throttled = sc_screen_should_throttle_raw_frame_locked(screen, now);
    if (throttled) {
        sc_fps_counter_add_skipped_frame(&screen->fps_counter);
    }

    previous_skipped = screen->pending_raw_frame_available;
    if (previous_skipped) {
        sc_screen_raw_frame_clear(screen, true);
    }

    screen->pending_raw_frame.display_number = display_number;
    screen->pending_raw_frame.size.width = width;
    screen->pending_raw_frame.size.height = height;
    screen->pending_raw_frame.fourcc = fourcc;
    screen->pending_raw_frame.format = format;
    screen->pending_raw_frame.stride = stride;
    screen->pending_raw_frame.pixels = pixels;
    screen->pending_raw_frame.size_bytes = size_bytes;
    screen->pending_raw_frame.dmabuf_fd = -1;
    screen->pending_raw_frame.received_tick = now;
    screen->pending_raw_frame.is_dmabuf = false;
    screen->pending_raw_frame.owns_pixels = owns_pixels;
    screen->pending_raw_frame_available = true;

    if (!screen->raw_frame_source_open) {
        screen->frame_size = screen->pending_raw_frame.size;
        screen->content_size = get_oriented_size(screen->frame_size,
                                                 screen->orientation);
        screen->raw_frame_source_open = true;
        open_window = true;
#ifndef NDEBUG
        screen->open = true;
#endif
    }

    if (!throttled && !screen->raw_frame_event_pending) {
        screen->raw_frame_event_pending = true;
        push_raw_frame_event = true;
    } else if (throttled) {
        sc_screen_schedule_raw_frame_refresh_locked(screen, now);
    }
    sc_mutex_unlock(&screen->mutex);

    if (open_window && !sc_push_event(SC_EVENT_OPEN_WINDOW)) {
        sc_screen_raw_frame_cancel_pending_push(screen, true);
        return false;
    }

    if (previous_skipped) {
        sc_fps_counter_add_skipped_frame(&screen->fps_counter);
    }

    if (push_raw_frame_event && !sc_push_event(SC_EVENT_NEW_RAW_FRAME)) {
        sc_screen_raw_frame_cancel_pending_push(screen, false);
        return false;
    }

    return true;
}

bool
sc_screen_push_dmabuf_frame(struct sc_screen *screen, uint32_t display_number,
                            uint32_t width, uint32_t height, uint32_t fourcc,
                            SDL_PixelFormat format, int dmabuf_fd,
                            uint32_t offset, uint32_t stride,
                            uint32_t modifier_hi, uint32_t modifier_lo) {
    assert(screen->video);

    if (!width || width > 0xFFFF || !height || height > 0xFFFF
            || format == SDL_PIXELFORMAT_UNKNOWN || dmabuf_fd < 0 || !stride) {
        LOGE("Invalid DMA-BUF frame");
#ifndef _WIN32
        if (dmabuf_fd >= 0) {
            close(dmabuf_fd);
        }
#endif
        return false;
    }

    bool open_window = false;
    bool previous_skipped;
    bool push_raw_frame_event = false;

    sc_mutex_lock(&screen->mutex);
    sc_tick now = sc_tick_now();
    previous_skipped = screen->pending_raw_frame_available;
    if (previous_skipped) {
        sc_screen_raw_frame_clear(screen, true);
    }

    screen->pending_raw_frame.display_number = display_number;
    screen->pending_raw_frame.size.width = width;
    screen->pending_raw_frame.size.height = height;
    screen->pending_raw_frame.fourcc = fourcc;
    screen->pending_raw_frame.format = format;
    screen->pending_raw_frame.stride = stride;
    screen->pending_raw_frame.pixels = NULL;
    screen->pending_raw_frame.size_bytes = 0;
    screen->pending_raw_frame.dmabuf_fd = dmabuf_fd;
    screen->pending_raw_frame.offset = offset;
    screen->pending_raw_frame.modifier_hi = modifier_hi;
    screen->pending_raw_frame.modifier_lo = modifier_lo;
    screen->pending_raw_frame.received_tick = now;
    screen->pending_raw_frame.is_dmabuf = true;
    screen->pending_raw_frame.owns_pixels = false;
    screen->pending_raw_frame_available = true;

    if (!screen->raw_frame_source_open) {
        screen->frame_size = screen->pending_raw_frame.size;
        screen->content_size = get_oriented_size(screen->frame_size,
                                                 screen->orientation);
        screen->raw_frame_source_open = true;
        open_window = true;
#ifndef NDEBUG
        screen->open = true;
#endif
    }
    if (!screen->raw_frame_event_pending) {
        screen->raw_frame_event_pending = true;
        push_raw_frame_event = true;
    }
    sc_mutex_unlock(&screen->mutex);

    if (open_window && !sc_push_event(SC_EVENT_OPEN_WINDOW)) {
        sc_screen_raw_frame_cancel_pending_push(screen, true);
        return false;
    }

    if (previous_skipped) {
        sc_fps_counter_add_skipped_frame(&screen->fps_counter);
    }

    if (push_raw_frame_event && !sc_push_event(SC_EVENT_NEW_RAW_FRAME)) {
        sc_screen_raw_frame_cancel_pending_push(screen, false);
        return false;
    }

    return true;
}

void
sc_screen_close_raw_frame_source(struct sc_screen *screen) {
    sc_mutex_lock(&screen->mutex);
    if (!screen->raw_frame_source_open) {
        SDL_TimerID timer =
            sc_screen_take_raw_frame_refresh_timer_locked(screen);
        sc_mutex_unlock(&screen->mutex);
        if (timer) {
            SDL_RemoveTimer(timer);
        }
        return;
    }

    screen->raw_frame_source_open = false;
    screen->raw_frame_event_pending = false;
    SDL_TimerID timer =
        sc_screen_take_raw_frame_refresh_timer_locked(screen);
#ifndef NDEBUG
    screen->open = false;
#endif
    sc_mutex_unlock(&screen->mutex);

    if (timer) {
        SDL_RemoveTimer(timer);
    }
}

bool
sc_screen_init(struct sc_screen *screen,
               const struct sc_screen_params *params) {
    screen->controller = params->controller;

    screen->resize_pending = false;
    screen->window_shown = false;
    screen->paused = false;
    screen->resume_frame = NULL;
    screen->orientation = SC_ORIENTATION_0;
    screen->disconnected = false;
    screen->disconnect_started = false;
    memset(&screen->pending_raw_frame, 0, sizeof(screen->pending_raw_frame));
    memset(&screen->raw_frame, 0, sizeof(screen->raw_frame));
    screen->pending_raw_frame.dmabuf_fd = -1;
    screen->raw_frame.dmabuf_fd = -1;
    screen->pending_raw_frame_available = false;
    screen->raw_frame_event_pending = false;
    screen->raw_frame_source_open = false;
    screen->raw_frame_refresh_timer = 0;
    memset(screen->raw_frame_buffer_pool, 0, sizeof(screen->raw_frame_buffer_pool));
    screen->raw_frame_buffer_next = 0;

    screen->video = params->video;
    screen->camera = params->camera;
    screen->window_aspect_ratio_lock = params->window_aspect_ratio_lock;
    screen->render_fit = params->render_fit;
    screen->flex_display = params->flex_display;
    screen->resize_display_using_pixel_size =
        params->resize_display_using_pixel_size;
    screen->cuttlefish_frames_socket = params->cuttlefish_frames_socket;
    screen->cuttlefish_display_id = params->cuttlefish_display_id;
    screen->flex_display_dpi = params->flex_display_dpi;
    screen->launch_display_dpi = params->flex_display_dpi;
    screen->initial_display_scale = 1.0f;
    screen->cuttlefish_resize_pid = SC_PROCESS_NONE;
    screen->last_requested_display_size.width = 0;
    screen->last_requested_display_size.height = 0;
    screen->last_resize_request_tick = 0;
    screen->initial_window_show_deferred = false;
    screen->initial_display_size.width = 0;
    screen->initial_display_size.height = 0;
    screen->initial_window_prepare_tick = 0;
    screen->initial_size_caught_up_tick = 0;
    screen->initial_window_show_timer = 0;
    screen->window_fade_in_show_tick = 0;
    screen->window_fade_in_start_tick = 0;
    screen->transient_stretch = false;
    screen->transient_stretch_source_size.width = 0;
    screen->transient_stretch_source_size.height = 0;
    screen->resize_preview_texture = NULL;
    screen->resize_preview_size.width = 0;
    screen->resize_preview_size.height = 0;
    screen->last_resize_event_tick = 0;
    screen->display_ready = false;
    screen->display_ready_tick = 0;
    screen->display_ready_raw_frame = false;
    screen->blur_fade_in_start_tick = 0;
    screen->blur_fade_start_tick = 0;
    screen->blur_fade_start_intensity = 0.0f;
    screen->resize_settle_timer = 0;
    screen->blur_fade_timer = 0;
    screen->last_raw_frame_render_tick = 0;
    screen->last_raw_frame_resize_tick = 0;
    screen->hotspot_button_down = false;
    screen->hotspot_press_started_in_hotspot = false;
    screen->hotspot_dragged = false;
    screen->hotspot_press_tick = 0;
    screen->hotspot_drag_pending = false;
    screen->restore_hotspot_press_pending = false;
    screen->restore_hotspot_press_tick = 0;
    screen->restore_hotspot_press_x = 0.f;
    screen->restore_hotspot_press_y = 0.f;

    screen->req.x = params->window_x;
    screen->req.y = params->window_y;
    screen->req.width = params->window_width;
    screen->req.height = params->window_height;
    screen->req.fullscreen = params->fullscreen;
    screen->req.start_fps_counter = params->start_fps_counter;

    screen->prevent_auto_resize = false;

    bool ok = sc_mutex_init(&screen->mutex);
    if (!ok) {
        return false;
    }

    ok = sc_frame_buffer_init(&screen->fb);
    if (!ok) {
        goto error_destroy_mutex;
    }

    if (!sc_fps_counter_init(&screen->fps_counter)) {
        goto error_destroy_frame_buffer;
    }

    if (screen->video) {
        screen->orientation = params->orientation;
        if (screen->orientation != SC_ORIENTATION_0) {
            LOGI("Initial display orientation set to %s",
                 sc_orientation_get_name(screen->orientation));
        }
    }

    // Always create the window hidden to prevent blinking during initialization
    uint32_t window_flags = SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN;
    if (params->always_on_top) {
        window_flags |= SDL_WINDOW_ALWAYS_ON_TOP;
    }
    if (params->window_borderless) {
        window_flags |= SDL_WINDOW_BORDERLESS;
    }
    if (params->video) {
        // The window will be shown on first frame
        window_flags |= SDL_WINDOW_RESIZABLE;
    }

    const char *title = params->window_title;
    assert(title);

    int x = SDL_WINDOWPOS_UNDEFINED;
    int y = SDL_WINDOWPOS_UNDEFINED;
    int width = 256;
    int height = 256;
    if (params->window_x != SC_WINDOW_POSITION_UNDEFINED) {
        x = params->window_x;
    }
    if (params->window_y != SC_WINDOW_POSITION_UNDEFINED) {
        y = params->window_y;
    }
    if (params->window_width) {
        width = params->window_width;
    }
    if (params->window_height) {
        height = params->window_height;
    }

    // The window will be positioned and sized on first video frame
    screen->window =
        sc_sdl_create_window(title, x, y, width, height, window_flags);
    if (!screen->window) {
        LOGE("Could not create window: %s", SDL_GetError());
        goto error_destroy_fps_counter;
    }

    sc_screen_set_window_min_size(screen->window);

    if (screen->flex_display && screen->launch_display_dpi) {
        SDL_DisplayID disp = SDL_GetDisplayForWindow(screen->window);
        if (disp) {
            float scale = SDL_GetDisplayContentScale(disp);
            if (scale > 0.0f) {
                screen->initial_display_scale = scale;
            }
        }
    }

    if (!SDL_SetWindowHitTest(screen->window, sc_screen_window_hit_test,
                              screen)) {
        LOGW("Could not set window hit-test callback: %s", SDL_GetError());
    }

    screen->renderer = SDL_CreateRenderer(screen->window, NULL);
    if (!screen->renderer) {
        LOGE("Could not create renderer: %s", SDL_GetError());
        goto error_destroy_window;
    }

#ifdef SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
    screen->gl_context = NULL;

    // starts with "opengl"
    const char *renderer_name = SDL_GetRendererName(screen->renderer);
    bool use_opengl = renderer_name && !strncmp(renderer_name, "opengl", 6);
    if (use_opengl) {
        // Persuade macOS to give us something better than OpenGL 2.1.
        // If we create a Core Profile context, we get the best OpenGL version.
        bool ok = SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                                      SDL_GL_CONTEXT_PROFILE_CORE);
        if (!ok) {
            LOGW("Could not set a GL Core Profile Context");
        }

        LOGD("Creating OpenGL Core Profile context");
        screen->gl_context = SDL_GL_CreateContext(screen->window);
        if (!screen->gl_context) {
            LOGE("Could not create OpenGL context: %s", SDL_GetError());
            goto error_destroy_renderer;
        }
    }
#endif

    bool mipmaps = params->video;
    ok = sc_texture_init(&screen->tex, screen->renderer, mipmaps);
    if (!ok) {
        goto error_destroy_renderer;
    }

    ok = SDL_StartTextInput(screen->window);
    if (!ok) {
        LOGE("Could not enable text input: %s", SDL_GetError());
        goto error_destroy_texture;
    }

    SDL_Surface *icon = sc_icon_load(SC_ICON_FILENAME_SCRCPY);
    if (icon) {
        if (!SDL_SetWindowIcon(screen->window, icon)) {
            LOGW("Could not set window icon: %s", SDL_GetError());
        }

        if (!params->video) {
            screen->content_size.width = icon->w;
            screen->content_size.height = icon->h;
            ok = sc_texture_set_from_surface(&screen->tex, icon);
            if (!ok) {
                LOGE("Could not set icon: %s", SDL_GetError());
            }
        }

        sc_icon_destroy(icon);
    } else {
        // not fatal
        LOGE("Could not load icon");

        if (!params->video) {
            // Make sure the content size is initialized
            screen->content_size.width = 256;
            screen->content_size.height = 256;
        }
    }

    screen->frame = av_frame_alloc();
    if (!screen->frame) {
        LOG_OOM();
        goto error_destroy_texture;
    }

    struct sc_input_manager_params im_params = {
        .controller = params->controller,
        .fp = params->fp,
        .screen = screen,
        .kp = params->kp,
        .mp = params->mp,
        .gp = params->gp,
        .camera = params->camera,
        .mouse_bindings = params->mouse_bindings,
        .legacy_paste = params->legacy_paste,
        .clipboard_autosync = params->clipboard_autosync,
        .shortcut_mods = params->shortcut_mods,
    };

    sc_input_manager_init(&screen->im, &im_params);

    // Initialize even if not used for simplicity
    sc_mouse_capture_init(&screen->mc, screen->window, params->shortcut_mods);

#ifdef CONTINUOUS_RESIZING_WORKAROUND
    if (screen->video) {
        ok = SDL_AddEventWatch(event_watcher, screen);
        if (!ok) {
            LOGW("Could not add event watcher for continuous resizing: %s",
                 SDL_GetError());
        }
    }
#endif

    memset(&screen->current_session, 0, sizeof(screen->current_session));

    static const struct sc_frame_sink_ops ops = {
        .open = sc_screen_frame_sink_open,
        .close = sc_screen_frame_sink_close,
        .push = sc_screen_frame_sink_push,
        .push_session = sc_screen_frame_sink_push_session,
    };

    screen->frame_sink.ops = &ops;

#ifndef NDEBUG
    screen->open = false;
#endif

    if (!screen->video) {
        // Show the window immediately
        screen->window_fade_in_show_tick = sc_tick_now();
        screen->window_fade_in_start_tick = 0;
        screen->window_shown = true;
        sc_sdl_show_window(screen->window);
        sc_screen_start_blur_animation_timer(screen);

        if (sc_screen_is_relative_mode(screen)) {
            // Capture mouse immediately if video mirroring is disabled
            sc_mouse_capture_set_active(&screen->mc, true);
        }
    }

    return true;

error_destroy_texture:
    sc_texture_destroy(&screen->tex);
error_destroy_renderer:
#ifdef SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
    if (screen->gl_context) {
        SDL_GL_DestroyContext(screen->gl_context);
    }
#endif
    SDL_DestroyRenderer(screen->renderer);
error_destroy_window:
    SDL_DestroyWindow(screen->window);
error_destroy_fps_counter:
    sc_fps_counter_destroy(&screen->fps_counter);
error_destroy_frame_buffer:
    sc_frame_buffer_destroy(&screen->fb);
error_destroy_mutex:
    sc_mutex_destroy(&screen->mutex);

    return false;
}

static void
sc_screen_show_initial_window(struct sc_screen *screen) {
    int x = screen->req.x != SC_WINDOW_POSITION_UNDEFINED
          ? screen->req.x : (int) SDL_WINDOWPOS_CENTERED;
    int y = screen->req.y != SC_WINDOW_POSITION_UNDEFINED
          ? screen->req.y : (int) SDL_WINDOWPOS_CENTERED;
    struct sc_point position = {
        .x = x,
        .y = y,
    };

    struct sc_size window_size =
        get_initial_optimal_size(screen->content_size, screen->req.width,
                                                       screen->req.height);

    assert(is_windowed(screen));
    if (!screen->flex_display) {
        set_aspect_ratio(screen, screen->content_size);
    }
    sc_sdl_set_window_size(screen->window, window_size);
    sc_sdl_set_window_position(screen->window, position);

    if (screen->req.fullscreen) {
        sc_screen_toggle_fullscreen(screen);
    }

    if (screen->req.start_fps_counter) {
        sc_fps_counter_start(&screen->fps_counter);
    }

    sc_screen_update_content_rect(screen);

    if (screen->flex_display) {
        screen->initial_window_show_deferred = true;
        screen->initial_window_prepare_tick = sc_tick_now();
        sc_screen_schedule_initial_window_show_timer(screen);
        sc_screen_maybe_request_display_resize(screen, true);
        screen->initial_display_size = screen->last_requested_display_size;
        // Do not let the initial relayout request throttle the compositor's
        // first post-show window size notification.
        screen->last_resize_request_tick = 0;
        if (screen->initial_display_size.width
                && screen->initial_display_size.height) {
            if (screen->tex.texture) {
                sc_screen_show_prepared_window(screen);
            }
            return;
        }
    }

    sc_screen_show_prepared_window(screen);
}

static void
sc_screen_show_prepared_window(struct sc_screen *screen) {
    if (screen->window_shown) {
        return;
    }

    SDL_TimerID timer;
    sc_mutex_lock(&screen->mutex);
    timer = sc_screen_take_initial_window_show_timer_locked(screen);
    sc_mutex_unlock(&screen->mutex);
    if (timer) {
        SDL_RemoveTimer(timer);
    }

    screen->initial_window_show_deferred = false;
    screen->window_fade_in_show_tick = sc_tick_now();
    screen->window_fade_in_start_tick = 0;
    screen->window_shown = true;
    if (!screen->flex_display) {
        set_aspect_ratio(screen, screen->content_size);
    }
    sc_sdl_show_window(screen->window);
    sc_screen_update_content_rect(screen);
    sc_screen_start_blur_animation_timer(screen);

    if (sc_screen_is_relative_mode(screen)) {
        sc_mouse_capture_set_active(&screen->mc, true);
    }
}

void
sc_screen_hide_window(struct sc_screen *screen) {
    sc_sdl_hide_window(screen->window);
    screen->window_shown = false;
}

void
sc_screen_interrupt(struct sc_screen *screen) {
    sc_fps_counter_interrupt(&screen->fps_counter);
}

static void
sc_screen_interrupt_disconnect(struct sc_screen *screen) {
    if (screen->disconnect_started) {
        sc_disconnect_interrupt(&screen->disconnect);
    }
}

void
sc_screen_join(struct sc_screen *screen) {
    sc_fps_counter_join(&screen->fps_counter);
    if (screen->disconnect_started) {
        sc_disconnect_join(&screen->disconnect);
    }
}

void
sc_screen_destroy(struct sc_screen *screen) {
#ifndef NDEBUG
    assert(!screen->open);
#endif
    if (screen->disconnect_started) {
        sc_disconnect_destroy(&screen->disconnect);
    }
    sc_screen_destroy_resize_preview(screen);
    sc_texture_destroy(&screen->tex);
    av_frame_free(&screen->frame);
    if (screen->raw_frame_refresh_timer) {
        SDL_RemoveTimer(screen->raw_frame_refresh_timer);
    }
    if (screen->initial_window_show_timer) {
        SDL_RemoveTimer(screen->initial_window_show_timer);
    }
    if (screen->resize_settle_timer) {
        SDL_RemoveTimer(screen->resize_settle_timer);
    }
    if (screen->blur_fade_timer) {
        SDL_RemoveTimer(screen->blur_fade_timer);
    }
    if (screen->cuttlefish_resize_pid != SC_PROCESS_NONE) {
        sc_process_close(screen->cuttlefish_resize_pid);
    }
    sc_screen_raw_frame_clear(screen, true);
    sc_screen_raw_frame_clear(screen, false);
    for (size_t i = 0; i < SC_RAW_FRAME_BUFFER_POOL_SIZE; ++i) {
        free(screen->raw_frame_buffer_pool[i].pixels);
    }
#ifdef SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
    SDL_GL_DestroyContext(screen->gl_context);
#endif
    SDL_DestroyRenderer(screen->renderer);
    SDL_DestroyWindow(screen->window);
    sc_fps_counter_destroy(&screen->fps_counter);
    sc_frame_buffer_destroy(&screen->fb);
    sc_mutex_destroy(&screen->mutex);

    SDL_Event event;
    int nevents = SDL_PeepEvents(&event, 1, SDL_GETEVENT,
                                 SC_EVENT_DISCONNECTED_ICON_LOADED,
                                 SC_EVENT_DISCONNECTED_ICON_LOADED);
    if (nevents == 1) {
        assert(event.type == SC_EVENT_DISCONNECTED_ICON_LOADED);
        // The event was posted, but not handled, the icon must be freed
        SDL_Surface *dangling_icon = event.user.data1;
        sc_icon_destroy(dangling_icon);
    }
}

static void
resize_for_content(struct sc_screen *screen, struct sc_size old_content_size,
                   struct sc_size new_content_size) {
    assert(screen->video);

    struct sc_size window_size = sc_sdl_get_window_size(screen->window);
    struct sc_size target_size = new_content_size;
    if (!screen->flex_display) {
        // Scale proportionally
        target_size.width = (uint32_t) window_size.width * target_size.width
                          / old_content_size.width;
        target_size.height = (uint32_t) window_size.height * target_size.height
                           / old_content_size.height;
    };
    target_size = get_optimal_size(target_size, new_content_size, true);
    assert(is_windowed(screen));
    set_aspect_ratio(screen, new_content_size);
    sc_sdl_set_window_size(screen->window, target_size);
}

static void
set_content_size(struct sc_screen *screen, struct sc_size new_content_size,
                 bool resize) {
    assert(screen->video);

    // In dpi resize mode, the host window size is the source of truth:
    // never resize the host window in response to frame/session size changes.
    if (resize && !screen->flex_display) {
        if (is_windowed(screen)) {
            resize_for_content(screen, screen->content_size, new_content_size);
        } else if (!screen->resize_pending) {
            // Store the windowed size to be able to compute the optimal size
            // once fullscreen/maximized/minimized are disabled
            screen->windowed_content_size = screen->content_size;
            screen->resize_pending = true;
        }
    }

    screen->content_size = new_content_size;
}

static void
apply_pending_resize(struct sc_screen *screen) {
    assert(screen->video);

    if (screen->flex_display) {
        screen->resize_pending = false;
        return;
    }

    assert(is_windowed(screen));
    if (screen->resize_pending) {
        resize_for_content(screen, screen->windowed_content_size,
                                   screen->content_size);
        screen->resize_pending = false;
    }
}

void
sc_screen_set_orientation(struct sc_screen *screen,
                          enum sc_orientation orientation) {
    assert(screen->video);

    if (orientation == screen->orientation) {
        return;
    }

    struct sc_size new_content_size =
        get_oriented_size(screen->frame_size, orientation);

    set_content_size(screen, new_content_size, true);

    screen->orientation = orientation;
    LOGI("Display orientation set to %s", sc_orientation_get_name(orientation));

    sc_screen_render(screen, true);
}

static bool
sc_screen_apply_frame(struct sc_screen *screen, bool can_resize) {
    assert(screen->video);
    assert(screen->window_shown);

    sc_fps_counter_add_rendered_frame(&screen->fps_counter);

    AVFrame *frame = screen->frame;
    struct sc_size new_frame_size = {frame->width, frame->height};

    if (screen->frame_size.width != new_frame_size.width
            || screen->frame_size.height != new_frame_size.height) {

        // frame dimension changed
        screen->frame_size = new_frame_size;

        struct sc_size new_content_size =
            get_oriented_size(new_frame_size, screen->orientation);
        set_content_size(screen, new_content_size, can_resize);
        sc_screen_update_content_rect(screen);
    }

    bool ok = sc_texture_set_from_frame(&screen->tex, frame);
    if (!ok) {
        return false;
    }

    sc_screen_render(screen, false);
    return true;
}

static bool
sc_screen_update_frame(struct sc_screen *screen) {
    assert(screen->video);

    if (screen->paused) {
        if (!screen->resume_frame) {
            screen->resume_frame = av_frame_alloc();
            if (!screen->resume_frame) {
                LOG_OOM();
                return false;
            }
        } else {
            av_frame_unref(screen->resume_frame);
        }
        sc_mutex_lock(&screen->mutex);
        sc_frame_buffer_consume(&screen->fb, screen->resume_frame);
        sc_mutex_unlock(&screen->mutex);
        return true;
    }

    av_frame_unref(screen->frame);
    sc_mutex_lock(&screen->mutex);
    sc_frame_buffer_consume(&screen->fb, screen->frame);
    // read with lock held
    bool can_resize = !screen->prevent_auto_resize;
    sc_mutex_unlock(&screen->mutex);
    return sc_screen_apply_frame(screen, can_resize);
}

static bool
sc_screen_apply_raw_frame(struct sc_screen *screen) {
    assert(screen->video);

    sc_fps_counter_add_rendered_frame(&screen->fps_counter);

    struct sc_size new_frame_size = screen->raw_frame.size;
    sc_screen_note_display_ready_raw_frame(screen);

    // Hold the last uploaded texture across the entire transient_stretch phase.
    // incoming frame data stays on the CPU side; when the hold lifts, this
    // same call proceeds to upload the latest frame.
    if (sc_screen_should_hold_resize(screen)) {
        if (sc_screen_try_release_resize_hold(screen)) {
            return true;
        }
        sc_mutex_lock(&screen->mutex);
        screen->last_raw_frame_render_tick = sc_tick_now();
        sc_mutex_unlock(&screen->mutex);
        sc_screen_render(screen, true);
        return true;
    }

    if (screen->frame_size.width != new_frame_size.width
            || screen->frame_size.height != new_frame_size.height) {
        screen->frame_size = new_frame_size;

        struct sc_size new_content_size =
            get_oriented_size(new_frame_size, screen->orientation);
        set_content_size(screen, new_content_size, true);
        sc_screen_update_content_rect(screen);
    }

    bool ok;
    if (screen->raw_frame.is_dmabuf) {
        ok = sc_texture_set_from_dmabuf_frame(&screen->tex,
                                              screen->raw_frame.size,
                                              screen->raw_frame.fourcc,
                                              screen->raw_frame.format,
                                              screen->raw_frame.dmabuf_fd,
                                              screen->raw_frame.offset,
                                              screen->raw_frame.stride,
                                              screen->raw_frame.modifier_hi,
                                              screen->raw_frame.modifier_lo);
    } else {
        ok = sc_texture_set_from_raw_frame(&screen->tex, screen->raw_frame.size,
                                           screen->raw_frame.format,
                                           screen->raw_frame.pixels,
                                           screen->raw_frame.stride);
    }
    if (!ok) {
        return false;
    }

    sc_mutex_lock(&screen->mutex);
    screen->last_raw_frame_render_tick = sc_tick_now();
    sc_mutex_unlock(&screen->mutex);

    if (!screen->window_shown && screen->initial_window_show_deferred) {
        struct sc_size source_size = screen->raw_frame.size;
        sc_tick now = sc_tick_now();
        bool size_caught_up =
            screen->initial_display_size.width
            && screen->initial_display_size.height
            && source_size.width == screen->initial_display_size.width
            && source_size.height == screen->initial_display_size.height;
        if (size_caught_up) {
            if (!screen->initial_size_caught_up_tick) {
                screen->initial_size_caught_up_tick = now;
            }
        } else {
            screen->initial_size_caught_up_tick = 0;
        }
        // Once the resolution matches, keep rendering in the background for an
        // extra settle grace so a freshly-booted desktop finishes drawing
        // before the window appears.
        bool settled =
            screen->initial_size_caught_up_tick
            && now - screen->initial_size_caught_up_tick
                    >= FLEX_DISPLAY_SHOW_SETTLE_GRACE;
        bool wait_expired =
            screen->initial_window_prepare_tick
            && now - screen->initial_window_prepare_tick
                    >= FLEX_DISPLAY_INITIAL_SHOW_TIMEOUT;

        // Honor the full settle grace once caught up; the timeout only applies
        // as a fallback when a matching frame never arrives.
        if (settled || (!size_caught_up && wait_expired)) {
            sc_screen_show_prepared_window(screen);
        } else {
            return true;
        }
    }

    if (!screen->window_shown) {
        return true;
    }

    sc_screen_render(screen, false);
    return true;
}

static void
sc_screen_release_resize_hold(struct sc_screen *screen) {
    screen->transient_stretch = false;
    screen->transient_stretch_source_size.width = 0;
    screen->transient_stretch_source_size.height = 0;
    screen->display_ready = false;
    screen->display_ready_tick = 0;
    screen->display_ready_raw_frame = false;
    // Order matters: start the fade first so the very next render (driven by
    // apply_raw_frame) already paints the new texture with the blur overlay.
    sc_screen_start_blur_fade(screen);
    sc_screen_apply_raw_frame(screen);
}

static void
sc_screen_note_display_ready_raw_frame(struct sc_screen *screen) {
    if (!screen->transient_stretch
            || !screen->display_ready
            || screen->display_ready_raw_frame
            || !screen->display_ready_tick
            || !screen->raw_frame.received_tick) {
        return;
    }

    sc_tick freshness_tick = screen->last_resize_request_tick
                           ? screen->last_resize_request_tick
                           : screen->display_ready_tick;
    if (screen->raw_frame.received_tick <= freshness_tick) {
        return;
    }

    bool post_ready_frame =
        screen->raw_frame.received_tick > screen->display_ready_tick;
    if (!post_ready_frame) {
        sc_tick now = sc_tick_now();
        sc_tick elapsed = now - screen->display_ready_tick;
        if (elapsed < FLEX_DISPLAY_POST_READY_FRAME_GRACE) {
            Uint32 delay_ms =
                SC_TICK_TO_MS(FLEX_DISPLAY_POST_READY_FRAME_GRACE - elapsed);
            sc_screen_schedule_resize_settle_after(screen,
                                                   delay_ms ? delay_ms : 1);
            return;
        }
    }

    screen->display_ready_raw_frame = true;
    if (sc_get_log_level() <= SC_LOG_LEVEL_VERBOSE) {
        LOGV("Resize hold has current-resize raw frame %ux%u",
             screen->raw_frame.size.width, screen->raw_frame.size.height);
    }
}

static bool
sc_screen_try_release_resize_hold(struct sc_screen *screen) {
    if (!screen->transient_stretch || !screen->display_ready) {
        return false;
    }

    if (!screen->display_ready_raw_frame) {
        sc_screen_note_display_ready_raw_frame(screen);
    }

    Uint32 quiet_remaining_ms =
        sc_screen_resize_quiet_remaining_ms(screen, sc_tick_now());
    if (quiet_remaining_ms) {
        sc_screen_schedule_resize_settle_after(screen, quiet_remaining_ms);
        return false;
    }

    if (screen->raw_frame_source_open
            && !screen->display_ready_raw_frame) {
        sc_screen_force_raw_frame_refresh(screen);
        return false;
    }

    sc_screen_release_resize_hold(screen);
    return true;
}

static bool
sc_screen_update_raw_frame(struct sc_screen *screen) {
    assert(screen->video);

    sc_mutex_lock(&screen->mutex);
    sc_tick now = sc_tick_now();
    screen->raw_frame_event_pending = false;
    if (!screen->pending_raw_frame_available) {
        sc_mutex_unlock(&screen->mutex);
        return true;
    }
    if (sc_screen_should_throttle_raw_frame_locked(screen, now)) {
        sc_fps_counter_add_skipped_frame(&screen->fps_counter);
        sc_screen_schedule_raw_frame_refresh_locked(screen, now);
        sc_mutex_unlock(&screen->mutex);
        return true;
    }

    sc_screen_raw_frame_clear(screen, false);
    screen->raw_frame = screen->pending_raw_frame;
    memset(&screen->pending_raw_frame, 0, sizeof(screen->pending_raw_frame));
    screen->pending_raw_frame.dmabuf_fd = -1;
    screen->pending_raw_frame_available = false;
    sc_mutex_unlock(&screen->mutex);

    return sc_screen_apply_raw_frame(screen);
}

void
sc_screen_set_paused(struct sc_screen *screen, bool paused) {
    assert(screen->video);

    if (!paused && !screen->paused) {
        // nothing to do
        return;
    }

    if (screen->paused && screen->resume_frame) {
        // If display screen was paused, refresh the frame immediately, even if
        // the new state is also paused.
        av_frame_free(&screen->frame);
        screen->frame = screen->resume_frame;
        screen->resume_frame = NULL;
        bool ok = sc_screen_apply_frame(screen, true);
        if (!ok) {
            LOGE("Resume frame update failed");
        }
    }

    if (!paused) {
        LOGI("Display screen unpaused");
    } else if (!screen->paused) {
        LOGI("Display screen paused");
    } else {
        LOGI("Display screen re-paused");
    }

    screen->paused = paused;
}

void
sc_screen_toggle_fullscreen(struct sc_screen *screen) {
    assert(screen->video);

    bool req_fullscreen =
        !(SDL_GetWindowFlags(screen->window) & SDL_WINDOW_FULLSCREEN);

    bool ok = SDL_SetWindowFullscreen(screen->window, req_fullscreen);
    if (!ok) {
        LOGW("Could not switch fullscreen mode: %s", SDL_GetError());
        return;
    }

    LOGD("Requested %s mode", req_fullscreen ? "fullscreen" : "windowed");
}

void
sc_screen_toggle_window_bordered(struct sc_screen *screen) {
    bool bordered = SDL_GetWindowFlags(screen->window) & SDL_WINDOW_BORDERLESS;
    struct sc_size window_size = sc_sdl_get_window_size(screen->window);
    struct sc_point window_position = sc_sdl_get_window_position(screen->window);
    int old_top = 0;
    int old_left = 0;
    int old_bottom = 0;
    int old_right = 0;
    bool have_old_borders = SDL_GetWindowBordersSize(screen->window, &old_top,
                                                     &old_left, &old_bottom,
                                                     &old_right);

    bool ok = SDL_SetWindowBordered(screen->window, bordered);
    if (!ok) {
        LOGW("Could not toggle window decorations: %s", SDL_GetError());
        return;
    }

    // Best effort: keep client area size and anchor when decorations
    // appear/disappear. Some compositors may ignore explicit positioning.
    sc_sdl_set_window_size(screen->window, window_size);

    int new_top = 0;
    int new_left = 0;
    int new_bottom = 0;
    int new_right = 0;
    bool have_new_borders = SDL_GetWindowBordersSize(screen->window, &new_top,
                                                     &new_left, &new_bottom,
                                                     &new_right);
    if (have_old_borders && have_new_borders) {
        struct sc_point new_position = {
            .x = window_position.x + old_left - new_left,
            .y = window_position.y + old_top - new_top,
        };
        sc_sdl_set_window_position(screen->window, new_position);
    }

    LOGD("Requested %s window decorations", bordered ? "enabled" : "disabled");
}

void
sc_screen_resize_to_fit(struct sc_screen *screen) {
    assert(screen->video);

    if (!is_windowed(screen)) {
        return;
    }

    struct sc_point point = sc_sdl_get_window_position(screen->window);
    struct sc_size window_size = sc_sdl_get_window_size(screen->window);

    struct sc_size optimal_size =
        get_optimal_size(window_size, screen->content_size, false);

    // Center the window related to the device screen
    assert(optimal_size.width <= window_size.width);
    assert(optimal_size.height <= window_size.height);

    struct sc_point new_position = {
        .x = point.x + (window_size.width - optimal_size.width) / 2,
        .y = point.y + (window_size.height - optimal_size.height) / 2,
    };

    set_aspect_ratio(screen, screen->content_size);
    sc_sdl_set_window_size(screen->window, optimal_size);
    sc_sdl_set_window_position(screen->window, new_position);
    LOGD("Resized to optimal size: %ux%u", optimal_size.width,
                                           optimal_size.height);
}

void
sc_screen_resize_to_pixel_perfect(struct sc_screen *screen) {
    assert(screen->video);

    if (!is_windowed(screen)) {
        return;
    }

    struct sc_size content_size = screen->content_size;
    set_aspect_ratio(screen, content_size);
    sc_sdl_set_window_size(screen->window, content_size);
    LOGD("Resized to pixel-perfect: %ux%u", content_size.width,
                                            content_size.height);
}

static void
sc_disconnect_on_icon_loaded(struct sc_disconnect *d, SDL_Surface *icon,
                             void *userdata) {
    (void) d;
    (void) userdata;

    bool ok = sc_push_event_with_data(SC_EVENT_DISCONNECTED_ICON_LOADED, icon);
    if (!ok) {
        sc_icon_destroy(icon);
    }
}

static void
sc_disconnect_on_timeout(struct sc_disconnect *d, void *userdata) {
    (void) d;
    (void) userdata;

    bool ok = sc_push_event(SC_EVENT_DISCONNECTED_TIMEOUT);
    (void) ok; // ignore failure
}

static void
sc_screen_note_raw_frame_resize_activity(struct sc_screen *screen) {
    if (!screen->raw_frame_source_open) {
        return;
    }

    sc_mutex_lock(&screen->mutex);
    sc_tick now = sc_tick_now();
    screen->last_raw_frame_resize_tick = now;
    sc_screen_schedule_raw_frame_refresh_locked(screen, now);
    sc_mutex_unlock(&screen->mutex);
}

static void
sc_screen_force_raw_frame_refresh(struct sc_screen *screen) {
    bool push_raw_frame_event = false;

    sc_mutex_lock(&screen->mutex);
    screen->last_raw_frame_resize_tick = 0;
    SDL_TimerID timer =
        sc_screen_take_raw_frame_refresh_timer_locked(screen);
    if (screen->raw_frame_source_open
            && screen->pending_raw_frame_available
            && !screen->raw_frame_event_pending) {
        screen->raw_frame_event_pending = true;
        push_raw_frame_event = true;
    }
    sc_mutex_unlock(&screen->mutex);

    if (timer) {
        SDL_RemoveTimer(timer);
    }
    if (push_raw_frame_event) {
        bool ok = sc_push_event(SC_EVENT_NEW_RAW_FRAME);
        (void) ok; // ignore failure
    }
}

static void
sc_screen_on_resize_settled(struct sc_screen *screen) {
    if (!screen->window_shown || !screen->flex_display) {
        return;
    }

    sc_tick now = sc_tick_now();
    Uint32 quiet_remaining_ms =
        sc_screen_resize_quiet_remaining_ms(screen, now);
    if (quiet_remaining_ms) {
        sc_screen_schedule_resize_settle_after(screen, quiet_remaining_ms);
        return;
    }

    sc_screen_maybe_request_display_resize(screen, true);
    if (sc_screen_snap_window_to_requested_pixel_size(screen)) {
        sc_screen_begin_resize_hold(screen, now, SC_RESIZE_PREVIEW_CONTENT);
        return;
    }

    sc_screen_force_raw_frame_refresh(screen);

    if (sc_screen_try_release_resize_hold(screen)) {
        return;
    }

    sc_screen_render(screen, true);
}

void
sc_screen_on_display_ready(struct sc_screen *screen, uint32_t display_id,
                           uint16_t width, uint16_t height) {
    (void) display_id; // single-display in flex mode; reserved for future use

    if (!screen->flex_display || !screen->transient_stretch) {
        // Not in a transitional state. Nothing to do.
        return;
    }

    // Sanity check: the device reports the size it actually resized to.
    // If that doesn't match our most recent request, the message is stale
    // (likely a previous resize finishing after we issued a newer one).
    // Ignore stale acks so we don't drop the hold mid-flight.
    uint16_t req_w = screen->last_requested_display_size.width;
    uint16_t req_h = screen->last_requested_display_size.height;
    if (req_w && req_h && (width != req_w || height != req_h)) {
        if (sc_get_log_level() <= SC_LOG_LEVEL_VERBOSE) {
            LOGV("DISPLAY_READY %ux%u doesn't match latest request %ux%u; "
                 "treating as stale", width, height, req_w, req_h);
        }
        return;
    }

    screen->display_ready = true;
    screen->display_ready_tick = sc_tick_now();
    screen->display_ready_raw_frame = false;
    sc_screen_note_display_ready_raw_frame(screen);

    Uint32 quiet_remaining_ms =
        sc_screen_resize_quiet_remaining_ms(screen,
                                            screen->display_ready_tick);
    if (quiet_remaining_ms) {
        sc_screen_schedule_resize_settle_after(screen, quiet_remaining_ms);
        return;
    }

    sc_screen_force_raw_frame_refresh(screen);
    if (!sc_screen_try_release_resize_hold(screen)) {
        sc_screen_render(screen, true);
    }
}

void
sc_screen_handle_event(struct sc_screen *screen, const SDL_Event *event) {
    sc_screen_poll_hotspot_state(screen);

    if (screen->hotspot_drag_pending) {
        screen->hotspot_drag_pending = false;
    }

    switch (event->type) {
        case SC_EVENT_OPEN_WINDOW:
            sc_screen_show_initial_window(screen);
            if (screen->window_shown) {
                sc_screen_render(screen, false);
            }
            return;
        case SC_EVENT_NEW_FRAME: {
            bool ok = sc_screen_update_frame(screen);
            if (!ok) {
                LOGE("Frame update failed\n");
            }
            return;
        }
        case SC_EVENT_NEW_RAW_FRAME: {
            bool ok = sc_screen_update_raw_frame(screen);
            if (!ok) {
                LOGE("Raw frame update failed\n");
            }
            return;
        }
        case SC_EVENT_RESIZE_SETTLED:
            sc_screen_on_resize_settled(screen);
            return;
        case SC_EVENT_BLUR_FADE_TICK:
            if (screen->window_shown) {
                sc_screen_render(screen, false);
            }
            return;
        case SC_EVENT_INITIAL_WINDOW_SHOW_TIMEOUT:
            if (!screen->window_shown && screen->initial_window_show_deferred) {
                sc_screen_show_prepared_window(screen);
                if (screen->window_shown) {
                    sc_screen_render(screen, false);
                }
            }
            return;
        case SDL_EVENT_WINDOW_EXPOSED:
            sc_screen_render(screen, true);
            return;
        case SDL_EVENT_MOUSE_MOTION:
            if (screen->video && screen->restore_hotspot_press_pending) {
                float dx = event->motion.x - screen->restore_hotspot_press_x;
                float dy = event->motion.y - screen->restore_hotspot_press_y;
                if (dx < 0) {
                    dx = -dx;
                }
                if (dy < 0) {
                    dy = -dy;
                }
                if (dx > SC_WINDOW_CLICK_MOVE_TOLERANCE
                        || dy > SC_WINDOW_CLICK_MOVE_TOLERANCE) {
                    screen->restore_hotspot_press_pending = false;
                }
            }
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            if (screen->video && event->button.button == SDL_BUTTON_LEFT) {
                uint64_t flags = SDL_GetWindowFlags(screen->window);
                bool constrained =
                    flags & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_MAXIMIZED);
                if (constrained
                        && sc_screen_is_drag_hotspot(screen->window,
                                                     event->button.x,
                                                     event->button.y)) {
                    screen->restore_hotspot_press_pending = true;
                    screen->restore_hotspot_press_tick = sc_tick_now();
                    screen->restore_hotspot_press_x = event->button.x;
                    screen->restore_hotspot_press_y = event->button.y;
                    // Do not inject the synthetic titlebar click to Android.
                    return;
                }
                screen->restore_hotspot_press_pending = false;
            }
            break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if (screen->video && event->button.button == SDL_BUTTON_LEFT
                    && screen->restore_hotspot_press_pending) {
                screen->restore_hotspot_press_pending = false;
                sc_tick elapsed = sc_tick_now()
                        - screen->restore_hotspot_press_tick;
                if (elapsed <= SC_WINDOW_DRAG_HOLD_DELAY) {
                    uint64_t flags = SDL_GetWindowFlags(screen->window);
                    bool fullscreen = flags & SDL_WINDOW_FULLSCREEN;
                    bool maximized = flags & SDL_WINDOW_MAXIMIZED;
                    if (fullscreen) {
                        sc_screen_start_restore_stretch(screen);
                        if (!SDL_SetWindowFullscreen(screen->window, false)) {
                            LOGW("Could not leave fullscreen mode: %s",
                                 SDL_GetError());
                        }
                    } else if (maximized) {
                        sc_screen_start_restore_stretch(screen);
                        if (!SDL_RestoreWindow(screen->window)) {
                            LOGW("Could not restore window: %s",
                                 SDL_GetError());
                        }
                    }
                }
                // Do not inject the synthetic titlebar click to Android.
                return;
            }
            break;
        case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
            sc_screen_set_window_min_size(screen->window);

            // Window moved to a display with a different content scale (DPI
            // ratio). Recompute flex_display_dpi proportionally and force an
            // immediate resize so Android's font/icon density stays correct.
            if (screen->flex_display && screen->launch_display_dpi
                    && screen->initial_display_scale > 0.0f) {
                SDL_DisplayID disp = SDL_GetDisplayForWindow(screen->window);
                if (disp) {
                    float new_scale = SDL_GetDisplayContentScale(disp);
                    if (new_scale > 0.0f) {
                        float ratio = new_scale / screen->initial_display_scale;
                        uint16_t new_dpi =
                            (uint16_t)(screen->launch_display_dpi * ratio + 0.5f);
                        if (new_dpi < 1) new_dpi = 1;
                        screen->flex_display_dpi = new_dpi;
                        LOGD("Display scale changed (%.2f→%.2f), DPI %u→%u",
                             screen->initial_display_scale, new_scale,
                             screen->launch_display_dpi, new_dpi);
                        sc_screen_maybe_request_display_resize(screen, true);
                    }
                }
            }
            return;
// If defined, then the actions are already performed by the event watcher
#ifndef CONTINUOUS_RESIZING_WORKAROUND
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        case SDL_EVENT_WINDOW_RESIZED:
            sc_screen_on_resize(screen);
            return;
#endif
        case SDL_EVENT_WINDOW_RESTORED:
            if (screen->video && is_windowed(screen)) {
                apply_pending_resize(screen);
                sc_screen_render(screen, true);
            }
            return;
        case SDL_EVENT_WINDOW_ENTER_FULLSCREEN:
            LOGD("Switched to fullscreen mode");
            assert(screen->video);
            return;
        case SDL_EVENT_WINDOW_LEAVE_FULLSCREEN:
            LOGD("Switched to windowed mode");
            assert(screen->video);
            if (is_windowed(screen)) {
                apply_pending_resize(screen);
                sc_screen_render(screen, true);
            }
            return;
        case SC_EVENT_DEVICE_DISCONNECTED:
            assert(!screen->disconnected);
            screen->disconnected = true;
            if (!screen->window_shown) {
                // No window open
                return;
            }

            sc_input_manager_handle_event(&screen->im, event);

            sc_texture_reset(&screen->tex);
            sc_screen_render(screen, true);

            sc_tick deadline = sc_tick_now() + SC_TICK_FROM_SEC(2);
            static const struct sc_disconnect_callbacks cbs = {
                .on_icon_loaded = sc_disconnect_on_icon_loaded,
                .on_timeout = sc_disconnect_on_timeout,
            };
            bool ok =
                sc_disconnect_start(&screen->disconnect, deadline, &cbs, NULL);
            if (ok) {
                screen->disconnect_started = true;
            }

            return;
    }

    if (sc_screen_is_relative_mode(screen)
            && sc_mouse_capture_handle_event(&screen->mc, event)) {
        // The mouse capture handler consumed the event
        return;
    }

    sc_input_manager_handle_event(&screen->im, event);
}

void
sc_screen_handle_disconnection(struct sc_screen *screen) {
    if (!screen->window_shown) {
        // No window open, quit immediately
        return;
    }

    if (!screen->disconnect_started) {
        // If sc_disconnect_start() failed, quit immediately
        return;
    }

    SDL_Event event;
    while (SDL_WaitEvent(&event)) {
        switch (event.type) {
            case SDL_EVENT_WINDOW_EXPOSED:
                sc_screen_render(screen, true);
                break;
            case SC_EVENT_DISCONNECTED_ICON_LOADED: {
                SDL_Surface *icon_disconnected = event.user.data1;
                assert(icon_disconnected);

                bool ok = sc_texture_set_from_surface(&screen->tex,
                                                      icon_disconnected);
                if (ok) {
                    screen->content_size.width = icon_disconnected->w;
                    screen->content_size.height = icon_disconnected->h;
                    sc_screen_render(screen, true);
                } else {
                    // not fatal
                    LOGE("Could not set disconnected icon");
                }

                sc_icon_destroy(icon_disconnected);
                break;
            }
            case SC_EVENT_DISCONNECTED_TIMEOUT:
                LOGD("Closing after device disconnection");
                return;
            case SDL_EVENT_QUIT:
                LOGD("User requested to quit");
                sc_screen_interrupt_disconnect(screen);
                return;
            default:
                sc_input_manager_handle_event(&screen->im, &event);
        }
    }
}

static struct sc_point
sc_screen_convert_drawable_to_coords(struct sc_screen *screen, int32_t x,
                                     int32_t y, struct sc_size oriented_size) {
    assert(screen->video);
    enum sc_orientation orientation = screen->orientation;

    int32_t w = oriented_size.width;
    int32_t h = oriented_size.height;

    // screen->rect must be initialized to avoid a division by zero
    assert(screen->rect.w && screen->rect.h);

    x = (int64_t) (x - screen->rect.x) * w / screen->rect.w;
    y = (int64_t) (y - screen->rect.y) * h / screen->rect.h;

    struct sc_point result;
    switch (orientation) {
        case SC_ORIENTATION_0:
            result.x = x;
            result.y = y;
            break;
        case SC_ORIENTATION_90:
            result.x = y;
            result.y = w - x;
            break;
        case SC_ORIENTATION_180:
            result.x = w - x;
            result.y = h - y;
            break;
        case SC_ORIENTATION_270:
            result.x = h - y;
            result.y = x;
            break;
        case SC_ORIENTATION_FLIP_0:
            result.x = w - x;
            result.y = y;
            break;
        case SC_ORIENTATION_FLIP_90:
            result.x = h - y;
            result.y = w - x;
            break;
        case SC_ORIENTATION_FLIP_180:
            result.x = x;
            result.y = h - y;
            break;
        default:
            assert(orientation == SC_ORIENTATION_FLIP_270);
            result.x = y;
            result.y = x;
            break;
    }

    return result;
}

struct sc_point
sc_screen_convert_drawable_to_frame_coords(struct sc_screen *screen,
                                           int32_t x, int32_t y) {
    return sc_screen_convert_drawable_to_coords(screen, x, y,
                                               screen->content_size);
}

struct sc_size
sc_screen_get_input_size(struct sc_screen *screen) {
    if (screen->raw_frame_source_open
            && screen->flex_display
            && screen->last_requested_display_size.width
            && screen->last_requested_display_size.height) {
        return screen->last_requested_display_size;
    }
    return screen->frame_size;
}

struct sc_point
sc_screen_convert_drawable_to_input_coords(struct sc_screen *screen,
                                           int32_t x, int32_t y) {
    struct sc_size input_size =
        get_oriented_size(sc_screen_get_input_size(screen),
                          screen->orientation);
    return sc_screen_convert_drawable_to_coords(screen, x, y, input_size);
}

struct sc_point
sc_screen_convert_window_to_frame_coords(struct sc_screen *screen,
                                         int32_t x, int32_t y) {
    sc_screen_hidpi_scale_coords(screen, &x, &y);
    return sc_screen_convert_drawable_to_frame_coords(screen, x, y);
}

struct sc_point
sc_screen_convert_window_to_input_coords(struct sc_screen *screen,
                                         int32_t x, int32_t y) {
    sc_screen_hidpi_scale_coords(screen, &x, &y);
    return sc_screen_convert_drawable_to_input_coords(screen, x, y);
}

void
sc_screen_hidpi_scale_coords(struct sc_screen *screen, int32_t *x, int32_t *y) {
    // take the HiDPI scaling (dw/ww and dh/wh) into account

    struct sc_size window_size = sc_sdl_get_window_size(screen->window);
    int64_t ww = window_size.width;
    int64_t wh = window_size.height;

    struct sc_size drawable_size =
        sc_sdl_get_window_size_in_pixels(screen->window);
    int64_t dw = drawable_size.width;
    int64_t dh = drawable_size.height;

    // scale for HiDPI (64 bits for intermediate multiplications)
    *x = (int64_t) *x * dw / ww;
    *y = (int64_t) *y * dh / wh;
}
