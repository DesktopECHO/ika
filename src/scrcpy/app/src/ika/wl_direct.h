#ifndef SC_WL_DIRECT_H
#define SC_WL_DIRECT_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <libavutil/buffer.h>
#include <libavutil/frame.h>
#include <SDL3/SDL.h>

#define SC_WL_DIRECT_MAX_BUFFERS 8

/**
 * Show frames held in the Cuttlefish frame slots (shared memory) by attaching
 * the slot itself to the window's Wayland surface, as a wl_shm buffer.
 *
 * For a compositor that takes the window's pixels from shared memory anyway
 * (WSLg): OpenGL then uploads each frame, draws it and reads it back for the
 * compositor, three full-frame copies the compositor's own one replaces.
 *
 * A frame stays referenced, and its slot unavailable to the server, until the
 * compositor releases its buffer.
 */
struct sc_wl_direct {
    bool enabled;

    void *wayland; // libwayland-client, loaded by SDL
    void *display; // struct wl_display *
    void *surface; // struct wl_surface * of the window
    void *queue; // struct wl_event_queue * of the objects below
    void *shm; // struct wl_shm *
    uint32_t surface_version;

    // The slots the pool maps (a reference to the cf_source's slots)
    AVBufferRef *pool_slots;
    void *pool; // struct wl_shm_pool *

    // Buffers the compositor has not released, with their frames
    struct sc_wl_direct_buffer {
        struct sc_wl_direct *owner;
        void *buffer; // struct wl_buffer *, NULL if the entry is free
        AVFrame *frame;
    } buffers[SC_WL_DIRECT_MAX_BUFFERS];
};

/**
 * Enable direct presentation for the window if its video driver is Wayland.
 * Return false (and leave it disabled) otherwise.
 */
bool
sc_wl_direct_init(struct sc_wl_direct *wd, SDL_Window *window);

void
sc_wl_direct_destroy(struct sc_wl_direct *wd);

/**
 * Whether the frame can be shown directly: it is in a frame slot, in a format
 * the compositor takes, and there is a free buffer entry.
 */
bool
sc_wl_direct_can_present(struct sc_wl_direct *wd, const AVFrame *frame);

/**
 * Attach the frame to the window's surface and commit it. The frame gets a new
 * reference, released with the buffer.
 */
bool
sc_wl_direct_present(struct sc_wl_direct *wd, const AVFrame *frame);

/**
 * Handle the compositor's buffer releases received meanwhile.
 */
void
sc_wl_direct_dispatch(struct sc_wl_direct *wd);

#endif
