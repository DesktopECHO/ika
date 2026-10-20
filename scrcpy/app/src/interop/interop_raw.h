#ifndef SC_INTEROP_RAW_H
#define SC_INTEROP_RAW_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <SDL3/SDL.h>

#include "egl.h"
#include "interop.h"
#include "opengl.h"

// The guest's hwcomposer cycles through a few color buffers, so the DMA-BUFs
// of consecutive frames are the same handful of buffers: keep their EGLImages
#define SC_INTEROP_RAW_DMA_BUF_CACHE_SIZE 6

/**
 * An imported DMA-BUF: its EGLImage, attached once to its own texture
 */
struct sc_interop_raw_dma_buf {
    AVFrame *frame; // NULL if the entry is free; keeps a fd of the DMA-BUF open

    // The DMA-BUF is identified by the inode of its fd
    dev_t dev;
    ino_t ino;

    // The entry is replaced if the same DMA-BUF comes with another layout
    uint32_t drm_format;
    int width;
    int height;
    uint32_t offset;
    uint32_t pitch;
    uint64_t modifier;

    SDL_Texture *texture; // its storage is the EGLImage
    EGLImageKHR image;

    uint64_t last_use; // for LRU eviction
};

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
    bool texture_is_dma_buf; // interop.texture belongs to a dma_bufs entry
    SDL_PixelFormat texture_format; // of a raw (in-memory) texture

    bool has_egl; // DMA-BUF import is available
    struct sc_egl egl;

    struct sc_interop_raw_dma_buf dma_bufs[SC_INTEROP_RAW_DMA_BUF_CACHE_SIZE];
    uint64_t dma_buf_clock; // incremented on every use of an entry
    uint64_t dma_buf_hits;
    uint64_t dma_buf_misses;
};

struct sc_interop_raw *
sc_interop_raw_new(SDL_Renderer *renderer, struct sc_opengl *gl);

#endif
