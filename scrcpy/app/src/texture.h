#ifndef SC_DISPLAY_H
#define SC_DISPLAY_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <libavutil/frame.h>
#include <SDL3/SDL.h>

#include "coords.h"
#include "opengl.h"

enum sc_texture_type {
    SC_TEXTURE_TYPE_FRAME,
    SC_TEXTURE_TYPE_RAW_FRAME,
    SC_TEXTURE_TYPE_DMABUF_FRAME,
    SC_TEXTURE_TYPE_ICON,
};

#define SC_DMABUF_TEXTURE_CACHE_SIZE 8

struct sc_dmabuf_texture_cache_entry {
    bool used;
    uint64_t last_used;
    uint64_t dev;
    uint64_t ino;
    struct sc_size size;
    uint32_t fourcc;
    SDL_PixelFormat format;
    uint32_t offset;
    uint32_t stride;
    uint32_t modifier_hi;
    uint32_t modifier_lo;
    uint32_t gl_texture;
    void *egl_image;
    void *egl_display;
    SDL_Texture *texture;
};

struct sc_texture {
    SDL_Renderer *renderer; // owned by the caller
    SDL_Texture *texture;
    // Only valid if texture != NULL
    struct sc_size texture_size;
    enum sc_texture_type texture_type;
    SDL_PixelFormat raw_format;

    struct sc_opengl gl;

    bool mipmaps;
    uint32_t texture_id; // only set if mipmaps is enabled
    uint32_t raw_texture_id;
    uint32_t raw_pbo_ids[3];
    uint32_t raw_pbo_index;
    bool raw_pbo_supported;
    bool raw_pbo_enabled;
    struct sc_dmabuf_texture_cache_entry
        dmabuf_cache[SC_DMABUF_TEXTURE_CACHE_SIZE];
    uint64_t dmabuf_cache_generation;
};

bool
sc_texture_init(struct sc_texture *tex, SDL_Renderer *renderer, bool mipmaps);

void
sc_texture_destroy(struct sc_texture *tex);

bool
sc_texture_set_from_frame(struct sc_texture *tex, const AVFrame *frame);

bool
sc_texture_set_from_raw_frame(struct sc_texture *tex, struct sc_size size,
                              SDL_PixelFormat format, const uint8_t *pixels,
                              uint32_t stride);

bool
sc_texture_set_from_dmabuf_frame(struct sc_texture *tex, struct sc_size size,
                                 uint32_t fourcc, SDL_PixelFormat format,
                                 int dmabuf_fd, uint32_t offset,
                                 uint32_t stride, uint32_t modifier_hi,
                                 uint32_t modifier_lo);

bool
sc_texture_set_from_surface(struct sc_texture *tex, SDL_Surface *surface);

void
sc_texture_reset(struct sc_texture *tex);

#endif
