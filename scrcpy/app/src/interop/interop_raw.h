#ifndef SC_INTEROP_RAW_H
#define SC_INTEROP_RAW_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL.h>

#include "egl.h"
#include "interop.h"
#include "opengl.h"

/**
 * Interop for uncompressed RGB frames (Cuttlefish frames), either in memory
 * (packed RGB formats) or as a DMA-BUF (AV_PIX_FMT_DRM_PRIME, imported through
 * EGL when the renderer is OpenGL).
 */
struct sc_interop_raw {
    struct sc_interop interop; // interop trait

    SDL_Renderer *renderer; // owned by the screen
    struct sc_opengl *gl; // NULL if the renderer is not OpenGL

    // Only valid if interop.texture != NULL
    SDL_PixelFormat texture_format;
    bool texture_is_dma_buf;

    bool has_egl; // DMA-BUF import is available
    struct sc_egl egl;
    uint32_t texture_id; // OpenGL texture of a DMA-BUF texture
    EGLImageKHR image;
    AVFrame *dma_buf_frame; // keeps the imported DMA-BUF alive
};

struct sc_interop_raw *
sc_interop_raw_new(SDL_Renderer *renderer, struct sc_opengl *gl);

#endif
