#include "flex.h"

#include <assert.h>
#include <inttypes.h>

#include "events.h"
#include "util/log.h"

// Host window quiet time before requesting a new display size: a drag produces
// a stream of sizes, while maximize, restore and fullscreen land on their final
// size at once
#define SC_FLEX_DRAG_DELAY SC_TICK_FROM_MS(200)
#define SC_FLEX_DISCRETE_DELAY SC_TICK_FROM_MS(30)
// Resizes this soon after a maximize/restore/fullscreen change belong to it
#define SC_FLEX_STATE_CHANGE_WINDOW SC_TICK_FROM_MS(250)
// After DISPLAY_READY, Android presents partially reflowed layouts while apps
// relayout. Cuttlefish only sends the frames the guest presents, so no new frame
// for this long means that the guest has finished drawing the new layout.
#define SC_FLEX_GUEST_IDLE SC_TICK_FROM_MS(120)
// For guests that keep presenting (video, animations), and for a resize that
// produced no frame
#define SC_FLEX_MAX_SETTLE SC_TICK_FROM_MS(1250)

#define SC_FLEX_BLUR_FADE_IN SC_TICK_FROM_MS(500)
#define SC_FLEX_BLUR_FADE_OUT SC_TICK_FROM_MS(500)
#define SC_FLEX_REVEAL SC_TICK_FROM_MS(500)
// Opacity of the blurred layer over the preview at full intensity
#define SC_FLEX_BLUR_OPACITY 0.66f
#define SC_FLEX_ANIMATION_INTERVAL SC_TICK_FROM_MS(16)
// Shown until the content is first revealed, and faded from
#define SC_FLEX_GRAY 0x33
// The device may make a display a bit smaller than requested, to align its size
// for the encoder
#define SC_FLEX_MAX_ALIGNMENT 16

static inline bool
sc_size_equals(struct sc_size a, struct sc_size b) {
    return a.width == b.width && a.height == b.height;
}

static inline bool
sc_size_is_set(struct sc_size size) {
    return size.width && size.height;
}

static struct sc_size
sc_flex_clamp(struct sc_size size) {
    size.width = MAX(size.width, SC_FLEX_MIN_WIDTH);
    size.height = MAX(size.height, SC_FLEX_MIN_HEIGHT);
    return size;
}

static uint32_t SDLCALL
sc_flex_timer_cb(void *userdata, SDL_TimerID id, uint32_t interval) {
    (void) userdata;
    (void) id;
    (void) interval;
    bool ok = sc_push_event(SC_EVENT_FLEX_TIMER);
    (void) ok;
    return 0; // one-shot
}

// Make sure that a timer event is posted no later than deadline
static void
sc_flex_schedule(struct sc_flex *flex, sc_tick deadline) {
    if (flex->timer && flex->timer_deadline <= deadline) {
        // An earlier timer is armed, it will reschedule
        return;
    }
    if (flex->timer) {
        SDL_RemoveTimer(flex->timer);
    }
    sc_tick now = sc_tick_now();
    uint32_t delay_ms = deadline > now ? SC_TICK_TO_MS(deadline - now) : 0;
    flex->timer = SDL_AddTimer(MAX(delay_ms, 1), sc_flex_timer_cb, NULL);
    flex->timer_deadline = deadline;
    if (!flex->timer) {
        LOGW("Could not add flex display timer: %s", SDL_GetError());
    }
}

static void
sc_flex_destroy_blur_levels(struct sc_flex *flex) {
    for (unsigned i = 0; i < SC_FLEX_BLUR_LEVELS; ++i) {
        if (flex->blur_levels[i]) {
            SDL_DestroyTexture(flex->blur_levels[i]);
            flex->blur_levels[i] = NULL;
        }
    }
    flex->blur_source_size.width = 0;
    flex->blur_source_size.height = 0;
    flex->preview_blur_valid = false;
}

static void
sc_flex_destroy_preview(struct sc_flex *flex) {
    if (flex->preview) {
        SDL_DestroyTexture(flex->preview);
        flex->preview = NULL;
    }
    flex->preview_blur_valid = false;
}

void
sc_flex_init(struct sc_flex *flex, struct sc_controller *controller,
             SDL_Renderer *renderer, bool raw) {
    flex->controller = controller;
    flex->renderer = renderer;
    flex->raw = raw;

    flex->pending.width = 0;
    flex->pending.height = 0;
    flex->pending_deadline = 0;
    flex->requested.width = 0;
    flex->requested.height = 0;
    flex->shown.width = 0;
    flex->shown.height = 0;
    flex->state_change_tick = 0;
    flex->ready_tick = 0;
    flex->ready_unchanged = false;
    flex->frame_tick = 0;

    // Until the first size is confirmed, the raw content is unknown
    flex->holding = raw;
    flex->revealed = !raw;
    flex->preview = NULL;
    flex->refresh_preview = false;
    flex->hold_tick = 0;
    flex->release_tick = 0;
    flex->release_reveal = false;
    for (unsigned i = 0; i < SC_FLEX_BLUR_LEVELS; ++i) {
        flex->blur_levels[i] = NULL;
    }
    flex->blur_source_size.width = 0;
    flex->blur_source_size.height = 0;
    flex->preview_blur_valid = false;

    flex->timer = 0;
    flex->timer_deadline = 0;
}

void
sc_flex_destroy(struct sc_flex *flex) {
    if (flex->timer) {
        SDL_RemoveTimer(flex->timer);
    }
    sc_flex_destroy_preview(flex);
    sc_flex_destroy_blur_levels(flex);
}

// Render src of texture (all of it if NULL) into the current render target as
// the mean of four bilinear samples offset diagonally by offset texels: one
// step of a dual Kawase blur
static bool
sc_flex_blur_pass(SDL_Renderer *renderer, SDL_Texture *texture,
                  const SDL_FRect *src, float offset) {
    SDL_FRect base;
    if (src) {
        base = *src;
    } else {
        base.x = 0;
        base.y = 0;
        if (!SDL_GetTextureSize(texture, &base.w, &base.h)) {
            return false;
        }
    }

    static const SDL_FPoint directions[] = {
        {-1, -1}, {1, 1}, {1, -1}, {-1, 1},
    };
    bool ok = true;
    for (unsigned i = 0; ok && i < ARRAY_LEN(directions); ++i) {
        SDL_FRect rect = base;
        rect.x += directions[i].x * offset;
        rect.y += directions[i].y * offset;
        // A running mean: sample n replaces 1/n of the result
        ok = SDL_SetTextureBlendMode(texture, i ? SDL_BLENDMODE_BLEND
                                                : SDL_BLENDMODE_NONE)
          && SDL_SetTextureAlphaMod(texture, 255 / (i + 1))
          && SDL_RenderTexture(renderer, texture, &rect, NULL);
    }
    return ok;
}

// Blur src of texture (all of it if NULL), and return it at half size (owned by
// flex), or NULL on error: it is halved into each blur level, then enlarged back
// up the levels. The work is done at reduced size, so it is cheap.
static SDL_Texture *
sc_flex_build_blur(struct sc_flex *flex, SDL_Texture *texture,
                   const SDL_FRect *src) {
    float w, h;
    if (src) {
        w = src->w;
        h = src->h;
    } else if (!SDL_GetTextureSize(texture, &w, &h)) {
        return NULL;
    }
    struct sc_size size = {w + 0.5f, h + 0.5f};
    if (!sc_size_is_set(size)) {
        return NULL;
    }

    SDL_Renderer *renderer = flex->renderer;
    if (!sc_size_equals(size, flex->blur_source_size)) {
        sc_flex_destroy_blur_levels(flex);
        int lw = size.width;
        int lh = size.height;
        for (unsigned i = 0; i < SC_FLEX_BLUR_LEVELS; ++i) {
            lw = lw > 1 ? (lw + 1) / 2 : 1;
            lh = lh > 1 ? (lh + 1) / 2 : 1;
            SDL_Texture *level =
                SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32,
                                  SDL_TEXTUREACCESS_TARGET, lw, lh);
            if (!level) {
                LOGW("Could not create blur texture: %s", SDL_GetError());
                sc_flex_destroy_blur_levels(flex);
                return NULL;
            }
            SDL_SetTextureScaleMode(level, SDL_SCALEMODE_LINEAR);
            flex->blur_levels[i] = level;
        }
        flex->blur_source_size = size;
    }

    SDL_Texture **levels = flex->blur_levels;
    SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_NONE);
    SDL_SetTextureAlphaMod(texture, 255);

    SDL_Texture *target = SDL_GetRenderTarget(renderer);
    // A plain halving already averages 2x2 pixels
    bool ok = SDL_SetRenderTarget(renderer, levels[0])
           && SDL_RenderTexture(renderer, texture, src, NULL);
    for (unsigned i = 1; ok && i < SC_FLEX_BLUR_LEVELS; ++i) {
        ok = SDL_SetRenderTarget(renderer, levels[i])
          && sc_flex_blur_pass(renderer, levels[i - 1], NULL, 1.0f);
    }
    for (unsigned i = SC_FLEX_BLUR_LEVELS - 1; ok && i > 0; --i) {
        ok = SDL_SetRenderTarget(renderer, levels[i - 1])
          && sc_flex_blur_pass(renderer, levels[i], NULL, 0.5f);
    }
    if (!SDL_SetRenderTarget(renderer, target)) {
        LOGW("Could not restore render target: %s", SDL_GetError());
    }

    if (!ok) {
        LOGW("Could not render blur: %s", SDL_GetError());
        return NULL;
    }

    SDL_Texture *blur = levels[0];
    SDL_SetTextureBlendMode(blur, SDL_BLENDMODE_BLEND);
    return blur;
}

static bool
sc_flex_render_blur(struct sc_flex *flex, SDL_Texture *blur,
                    const SDL_FRect *dst, float intensity) {
    if (!blur || intensity <= 0) {
        return true;
    }
    float opacity = SC_FLEX_BLUR_OPACITY * MIN(intensity, 1.0f);
    return SDL_SetTextureAlphaModFloat(blur, opacity)
        && SDL_RenderTexture(flex->renderer, blur, NULL, dst);
}

static void
sc_flex_capture_preview(struct sc_flex *flex, SDL_Texture *live,
                        const SDL_FRect *live_src) {
    sc_flex_destroy_preview(flex);

    if (!live || !live_src || live_src->w < 1 || live_src->h < 1) {
        return;
    }

    SDL_Renderer *renderer = flex->renderer;
    SDL_Texture *preview =
        SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32,
                          SDL_TEXTUREACCESS_TARGET, live_src->w, live_src->h);
    if (!preview) {
        LOGW("Could not create preview texture: %s", SDL_GetError());
        return;
    }
    SDL_SetTextureScaleMode(preview, SDL_SCALEMODE_LINEAR);

    SDL_Texture *target = SDL_GetRenderTarget(renderer);
    SDL_SetTextureBlendMode(live, SDL_BLENDMODE_NONE);
    bool ok = SDL_SetRenderTarget(renderer, preview)
           && SDL_RenderTexture(renderer, live, live_src, NULL);
    if (!SDL_SetRenderTarget(renderer, target)) {
        LOGW("Could not restore render target: %s", SDL_GetError());
    }
    if (!ok) {
        LOGW("Could not capture preview: %s", SDL_GetError());
        SDL_DestroyTexture(preview);
        return;
    }

    flex->preview = preview;
}

static void
sc_flex_start_hold(struct sc_flex *flex, SDL_Texture *live,
                   const SDL_FRect *live_src, sc_tick now) {
    assert(!flex->holding);
    flex->holding = true;
    flex->hold_tick = now;
    flex->release_tick = 0;
    // A previous request is settled, wait for the next one
    flex->ready_tick = 0;
    if (flex->raw) {
        sc_flex_capture_preview(flex, live, live_src);
    }
    // Animate the blur fade-in
    sc_flex_schedule(flex, now + SC_FLEX_ANIMATION_INTERVAL);
}

static void
sc_flex_release(struct sc_flex *flex, sc_tick now) {
    assert(flex->holding);
    LOGD("Flex display: showing %" PRIu16 "x%" PRIu16,
         flex->requested.width, flex->requested.height);
    flex->holding = false;
    flex->ready_tick = 0;
    if (flex->raw) {
        flex->shown = flex->requested;
    }
    flex->release_tick = now;
    flex->release_reveal = !flex->revealed;
    flex->revealed = true;
    sc_flex_destroy_preview(flex);
    sc_flex_schedule(flex, now + SC_FLEX_ANIMATION_INTERVAL);
}

void
sc_flex_on_window_size(struct sc_flex *flex, struct sc_size size,
                       SDL_Texture *live, const SDL_FRect *live_src) {
    size = sc_flex_clamp(size);
    if (sc_size_equals(size, flex->pending)) {
        return;
    }

    sc_tick now = sc_tick_now();
    bool discrete = flex->state_change_tick
                 && now - flex->state_change_tick < SC_FLEX_STATE_CHANGE_WINDOW;
    flex->pending = size;
    flex->pending_deadline = now + (discrete ? SC_FLEX_DISCRETE_DELAY
                                             : SC_FLEX_DRAG_DELAY);

    // Before the first video frame, there is nothing to blur
    bool has_content = flex->raw || sc_size_is_set(flex->shown);
    if (has_content && !flex->holding && !sc_size_equals(size, flex->shown)) {
        sc_flex_start_hold(flex, live, live_src, now);
    }

    sc_flex_schedule(flex, flex->pending_deadline);
}

void
sc_flex_on_window_state_changed(struct sc_flex *flex) {
    flex->state_change_tick = sc_tick_now();
}

void
sc_flex_on_display_ready(struct sc_flex *flex, struct sc_size size) {
    if (!flex->raw || !sc_size_equals(size, flex->requested)) {
        // Obsolete
        return;
    }

    sc_tick now = sc_tick_now();
    flex->ready_tick = now;
    flex->ready_unchanged = sc_size_equals(size, flex->shown);
    sc_flex_schedule(flex, now);
}

// Whether a video frame has the size of a display requested at the given size
static bool
sc_flex_frame_matches(struct sc_size frame, struct sc_size requested) {
    return frame.width <= requested.width && frame.height <= requested.height
        && requested.width - frame.width < SC_FLEX_MAX_ALIGNMENT
        && requested.height - frame.height < SC_FLEX_MAX_ALIGNMENT;
}

void
sc_flex_on_frame(struct sc_flex *flex, struct sc_size frame_size) {
    sc_tick now = sc_tick_now();
    flex->frame_tick = now;

    if (flex->raw) {
        if (flex->holding && flex->ready_tick) {
            sc_flex_schedule(flex, now + SC_FLEX_GUEST_IDLE);
        }
        return;
    }

    // The video frames have the display size
    flex->shown = frame_size;
    if (flex->holding && flex->ready_tick
            && sc_size_equals(flex->pending, flex->requested)
            && sc_flex_frame_matches(frame_size, flex->requested)) {
        sc_flex_release(flex, now);
    }
}

bool
sc_flex_on_timer(struct sc_flex *flex) {
    flex->timer = 0; // one-shot, already expired (or about to)
    sc_tick now = sc_tick_now();
    sc_tick next = 0;
#define SC_NEXT(T) next = next ? MIN(next, (T)) : (T)

    if (sc_size_is_set(flex->pending)
            && !sc_size_equals(flex->pending, flex->requested)) {
        if (now >= flex->pending_deadline) {
            flex->requested = flex->pending;
            flex->ready_tick = 0;
            if (!flex->raw) {
                // No DISPLAY_READY: the frames at the new size tell it
                flex->ready_tick = now;
                flex->ready_unchanged =
                    sc_flex_frame_matches(flex->shown, flex->requested);
            }
            LOGD("Flex display: request %" PRIu16 "x%" PRIu16,
                 flex->requested.width, flex->requested.height);
            sc_controller_resize_display(flex->controller,
                                         flex->requested.width,
                                         flex->requested.height);
        } else {
            SC_NEXT(flex->pending_deadline);
        }
    }

    bool render = false;
    if (flex->holding && flex->ready_tick) {
        sc_tick max_deadline = flex->ready_tick + SC_FLEX_MAX_SETTLE;
        // Raw frames are only sent when the guest draws: wait for it to stop
        sc_tick idle_deadline = flex->frame_tick + SC_FLEX_GUEST_IDLE;
        bool drawn = flex->raw && flex->frame_tick > flex->ready_tick
                  && now >= idle_deadline;
        if (flex->ready_unchanged || drawn || now >= max_deadline) {
            if (sc_size_equals(flex->pending, flex->requested)) {
                sc_flex_release(flex, now);
            } else {
                // The window has been resized again meanwhile: keep holding,
                // with the newly drawn content (video frames are stretched as
                // they come)
                LOGD("Flex display: drawn %" PRIu16 "x%" PRIu16
                     ", still resizing", flex->requested.width,
                     flex->requested.height);
                flex->ready_tick = 0;
                if (flex->raw) {
                    flex->shown = flex->requested;
                    flex->refresh_preview = true;
                }
            }
            render = true;
        } else if (flex->raw && flex->frame_tick > flex->ready_tick) {
            SC_NEXT(MIN(idle_deadline, max_deadline));
        } else {
            SC_NEXT(max_deadline);
        }
    }

    // Animations
    bool fading_in = flex->holding && (flex->preview || !flex->raw)
                  && now - flex->hold_tick < SC_FLEX_BLUR_FADE_IN;
    sc_tick fade_out = flex->release_reveal ? SC_FLEX_REVEAL
                                            : SC_FLEX_BLUR_FADE_OUT;
    bool fading_out = flex->release_tick
                   && now - flex->release_tick < fade_out;
    if (fading_in || fading_out) {
        render = true;
        SC_NEXT(now + SC_FLEX_ANIMATION_INTERVAL);
    } else if (flex->release_tick && !flex->holding) {
        // Render the end of the fade
        flex->release_tick = 0;
        render = true;
    }

    if (next) {
        sc_flex_schedule(flex, next);
    }
#undef SC_NEXT
    return render;
}

static float
sc_flex_progress(sc_tick start, sc_tick duration, sc_tick now) {
    if (!start || now - start >= duration) {
        return 1;
    }
    return (float) (now - start) / duration;
}

bool
sc_flex_render_raw(struct sc_flex *flex, SDL_Texture *live,
                   const SDL_FRect *live_src, const SDL_FRect *dst) {
    SDL_Renderer *renderer = flex->renderer;
    sc_tick now = sc_tick_now();

    if (flex->holding) {
        if (flex->refresh_preview && live) {
            sc_flex_capture_preview(flex, live, live_src);
            flex->refresh_preview = false;
        }

        if (!flex->preview) {
            // Nothing to show yet
            SDL_SetRenderDrawColor(renderer, SC_FLEX_GRAY, SC_FLEX_GRAY,
                                   SC_FLEX_GRAY, 0xFF);
            return SDL_RenderFillRect(renderer, dst);
        }

        SDL_SetTextureBlendMode(flex->preview, SDL_BLENDMODE_NONE);
        SDL_SetTextureAlphaMod(flex->preview, 255);
        bool ok = SDL_RenderTexture(renderer, flex->preview, NULL, dst);
        if (!flex->preview_blur_valid) {
            // The preview is static, blur it once
            flex->preview_blur_valid =
                sc_flex_build_blur(flex, flex->preview, NULL) != NULL;
        }
        if (flex->preview_blur_valid) {
            float t = sc_flex_progress(flex->hold_tick, SC_FLEX_BLUR_FADE_IN,
                                       now);
            ok &= sc_flex_render_blur(flex, flex->blur_levels[0], dst, t);
        }
        return ok;
    }

    if (!live) {
        return true;
    }

    SDL_SetTextureBlendMode(live, SDL_BLENDMODE_NONE);
    SDL_SetTextureAlphaMod(live, 255);
    bool ok = SDL_RenderTexture(renderer, live, live_src, dst);

    if (flex->release_tick) {
        if (flex->release_reveal) {
            // Fade in from gray
            float t = sc_flex_progress(flex->release_tick, SC_FLEX_REVEAL, now);
            SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
            SDL_SetRenderDrawColorFloat(renderer, SC_FLEX_GRAY / 255.f,
                                        SC_FLEX_GRAY / 255.f,
                                        SC_FLEX_GRAY / 255.f, 1 - t);
            ok &= SDL_RenderFillRect(renderer, dst);
            SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_NONE);
        } else {
            // The new content sharpens up
            float t = sc_flex_progress(flex->release_tick,
                                       SC_FLEX_BLUR_FADE_OUT, now);
            flex->preview_blur_valid = false;
            SDL_Texture *blur = sc_flex_build_blur(flex, live, live_src);
            ok &= sc_flex_render_blur(flex, blur, dst, 1 - t);
        }
    }

    return ok;
}

bool
sc_flex_render_overlay(struct sc_flex *flex, SDL_Texture *live,
                       const SDL_FRect *dst) {
    assert(!flex->raw);

    float intensity;
    sc_tick now = sc_tick_now();
    if (flex->holding) {
        intensity = sc_flex_progress(flex->hold_tick, SC_FLEX_BLUR_FADE_IN, now);
    } else if (flex->release_tick) {
        intensity = 1 - sc_flex_progress(flex->release_tick,
                                         SC_FLEX_BLUR_FADE_OUT, now);
    } else {
        return true;
    }

    if (!live || intensity <= 0) {
        return true;
    }

    SDL_Texture *blur = sc_flex_build_blur(flex, live, NULL);
    return sc_flex_render_blur(flex, blur, dst, intensity);
}
