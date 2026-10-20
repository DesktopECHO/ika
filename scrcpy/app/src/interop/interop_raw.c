#include "interop_raw.h"

#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <libavutil/hwcontext_drm.h>
#include <libavutil/pixdesc.h>

#include "util/log.h"

/** Downcast interop to sc_interop_raw */
#define DOWNCAST(INTEROP) \
    container_of(INTEROP, struct sc_interop_raw, interop)

#define SC_FOURCC(a, b, c, d) \
    ((uint32_t) (a) | ((uint32_t) (b) << 8) | ((uint32_t) (c) << 16) \
        | ((uint32_t) (d) << 24))

// Log the DMA-BUF cache statistics every N imports (debug level)
#define SC_INTEROP_RAW_DMA_BUF_STATS_PERIOD 1000

// The frames are opaque: formats with alpha are shown as their X variant, so
// that an undefined alpha channel cannot make them transparent
static SDL_PixelFormat
sc_interop_raw_get_sdl_format(enum AVPixelFormat format) {
    switch (format) {
        case AV_PIX_FMT_BGR0:
        case AV_PIX_FMT_BGRA:
            return SDL_PIXELFORMAT_BGRX32;
        case AV_PIX_FMT_RGB0:
        case AV_PIX_FMT_RGBA:
            return SDL_PIXELFORMAT_RGBX32;
        case AV_PIX_FMT_0RGB:
        case AV_PIX_FMT_ARGB:
            return SDL_PIXELFORMAT_XRGB32;
        case AV_PIX_FMT_0BGR:
        case AV_PIX_FMT_ABGR:
            return SDL_PIXELFORMAT_XBGR32;
        default:
            return SDL_PIXELFORMAT_UNKNOWN;
    }
}

// Same for the DRM formats of DMA-BUF frames
static uint32_t
sc_interop_raw_get_opaque_drm_format(uint32_t fourcc) {
    switch (fourcc) {
        case SC_FOURCC('A', 'R', '2', '4'):
            return SC_FOURCC('X', 'R', '2', '4');
        case SC_FOURCC('A', 'B', '2', '4'):
            return SC_FOURCC('X', 'B', '2', '4');
        case SC_FOURCC('R', 'A', '2', '4'):
            return SC_FOURCC('R', 'X', '2', '4');
        case SC_FOURCC('B', 'A', '2', '4'):
            return SC_FOURCC('B', 'X', '2', '4');
        default:
            return fourcc;
    }
}

static void
sc_interop_raw_release_dma_buf(struct sc_interop_raw *raw,
                               struct sc_interop_raw_dma_buf *entry) {
    assert(entry->frame);
    if (raw->interop.texture == entry->texture) {
        // The entry on screen is dropped
        raw->interop.texture = NULL;
    }
    sc_egl_destroy_image(&raw->egl, entry->image);
    entry->image = EGL_NO_IMAGE_KHR;
    SDL_DestroyTexture(entry->texture);
    entry->texture = NULL;
    av_frame_free(&entry->frame);
}

static void
sc_interop_raw_clear_dma_bufs(struct sc_interop_raw *raw) {
    for (size_t i = 0; i < ARRAY_LEN(raw->dma_bufs); ++i) {
        struct sc_interop_raw_dma_buf *entry = &raw->dma_bufs[i];
        if (entry->frame) {
            sc_interop_raw_release_dma_buf(raw, entry);
        }
    }
}

static void
sc_interop_raw_reset(struct sc_interop *interop) {
    struct sc_interop_raw *raw = DOWNCAST(interop);
    if (interop->texture && !raw->texture_is_dma_buf) {
        SDL_DestroyTexture(interop->texture);
    }
    interop->texture = NULL;
    sc_interop_raw_clear_dma_bufs(raw);
}

static void
sc_interop_raw_destroy(struct sc_interop *interop) {
    sc_interop_raw_reset(interop);
}

static void
sc_interop_raw_show_texture(struct sc_interop_raw *raw, SDL_Texture *texture,
                            struct sc_size size, bool dma_buf) {
    struct sc_interop *interop = &raw->interop;
    bool announce = !interop->texture
                 || interop->frame_size.width != size.width
                 || interop->frame_size.height != size.height
                 || raw->texture_is_dma_buf != dma_buf;
    interop->texture = texture;
    interop->frame_size = size;
    raw->texture_is_dma_buf = dma_buf;
    if (announce) {
        LOGI("Texture (%s): %" PRIu16 "x%" PRIu16, dma_buf ? "DMA-BUF" : "raw",
             size.width, size.height);
    }
}

static bool
sc_interop_raw_ensure_texture(struct sc_interop_raw *raw, struct sc_size size,
                              SDL_PixelFormat format) {
    struct sc_interop *interop = &raw->interop;
    if (interop->texture && !raw->texture_is_dma_buf
            && interop->frame_size.width == size.width
            && interop->frame_size.height == size.height
            && raw->texture_format == format) {
        return true;
    }

    // Also drops the DMA-BUF cache: the frames are no longer DMA-BUFs
    sc_interop_raw_reset(interop);

    SDL_Texture *texture = SDL_CreateTexture(raw->renderer, format,
                                             SDL_TEXTUREACCESS_STATIC,
                                             size.width, size.height);
    if (!texture) {
        LOGE("Could not create texture: %s", SDL_GetError());
        return false;
    }

    raw->texture_format = format;
    sc_interop_raw_show_texture(raw, texture, size, false);
    return true;
}

static struct sc_interop_raw_dma_buf *
sc_interop_raw_find_dma_buf(struct sc_interop_raw *raw, dev_t dev, ino_t ino) {
    for (size_t i = 0; i < ARRAY_LEN(raw->dma_bufs); ++i) {
        struct sc_interop_raw_dma_buf *entry = &raw->dma_bufs[i];
        if (entry->frame && entry->dev == dev && entry->ino == ino) {
            return entry;
        }
    }
    return NULL;
}

// Return a free entry, evicting the least recently used one if necessary
static struct sc_interop_raw_dma_buf *
sc_interop_raw_get_free_dma_buf(struct sc_interop_raw *raw) {
    struct sc_interop_raw_dma_buf *lru = NULL;
    for (size_t i = 0; i < ARRAY_LEN(raw->dma_bufs); ++i) {
        struct sc_interop_raw_dma_buf *entry = &raw->dma_bufs[i];
        if (!entry->frame) {
            return entry;
        }
        if (!lru || entry->last_use < lru->last_use) {
            lru = entry;
        }
    }

    assert(lru);
    LOGD("DMA-BUF cache full, dropping buffer %llu",
         (unsigned long long) lru->ino);
    sc_interop_raw_release_dma_buf(raw, lru);
    return lru;
}

// Import the DMA-BUF into a new entry (which must be free)
static bool
sc_interop_raw_create_dma_buf(struct sc_interop_raw *raw,
                              struct sc_interop_raw_dma_buf *entry,
                              const AVFrame *frame, dev_t dev, ino_t ino,
                              uint32_t drm_format,
                              const struct sc_egl_dma_buf_plane *plane) {
    assert(!entry->frame);

    // The EGLImage replaces the texture storage, the format only tells SDL to
    // sample it without swizzling
    SDL_Texture *texture = SDL_CreateTexture(raw->renderer,
                                             SDL_PIXELFORMAT_RGBA32,
                                             SDL_TEXTUREACCESS_STATIC,
                                             frame->width, frame->height);
    if (!texture) {
        LOGE("Could not create texture: %s", SDL_GetError());
        return false;
    }

    SDL_PropertiesID props = SDL_GetTextureProperties(texture);
    const char *key = raw->gl->is_opengles
                    ? SDL_PROP_TEXTURE_OPENGLES2_TEXTURE_NUMBER
                    : SDL_PROP_TEXTURE_OPENGL_TEXTURE_NUMBER;
    int64_t texture_id = props ? SDL_GetNumberProperty(props, key, 0) : 0;
    if (!texture_id) {
        LOGE("Could not get texture id: %s", SDL_GetError());
        goto error_destroy_texture;
    }
    assert(!(texture_id & ~0xFFFFFFFF)); // fits in uint32_t

    EGLImageKHR image =
        sc_egl_create_image_dma_buf(&raw->egl, drm_format, frame->width,
                                    frame->height, plane);
    if (image == EGL_NO_IMAGE_KHR) {
        LOGE("Could not import DMA-BUF as EGLImage (EGL error %#x)",
             raw->egl.GetError());
        goto error_destroy_texture;
    }

    // Invalidate the SDL OpenGL cache before touching the texture behind its
    // back
    if (!SDL_FlushRenderer(raw->renderer)) {
        LOGD("Could not flush renderer before DMA-BUF import: %s",
             SDL_GetError());
    }

    struct sc_opengl *gl = raw->gl;
    while (gl->GetError()); // Clear any errors left
    gl->BindTexture(GL_TEXTURE_2D, (uint32_t) texture_id);
    raw->egl.EGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);
    gl->BindTexture(GL_TEXTURE_2D, 0);
    GLenum gl_error = gl->GetError();
    if (gl_error) {
        LOGE("Could not attach the EGLImage to the texture (GL error %#x)",
             gl_error);
        goto error_destroy_image;
    }

    AVFrame *ref = av_frame_clone(frame);
    if (!ref) {
        LOG_OOM();
        goto error_destroy_image;
    }

    entry->frame = ref;
    entry->dev = dev;
    entry->ino = ino;
    entry->drm_format = drm_format;
    entry->width = frame->width;
    entry->height = frame->height;
    entry->offset = plane->offset;
    entry->pitch = plane->pitch;
    entry->modifier = plane->modifier;
    entry->texture = texture;
    entry->image = image;
    return true;

error_destroy_image:
    sc_egl_destroy_image(&raw->egl, image);
error_destroy_texture:
    SDL_DestroyTexture(texture);
    return false;
}

static bool
sc_interop_raw_import_dma_buf(struct sc_interop_raw *raw,
                              const AVFrame *frame) {
    if (!raw->has_egl) {
        LOGE("DMA-BUF frames require an OpenGL renderer with EGL DMA-BUF "
             "import");
        return false;
    }

    const AVDRMFrameDescriptor *desc =
        (const AVDRMFrameDescriptor *) frame->data[0];
    if (!desc || desc->nb_objects != 1 || desc->nb_layers != 1
            || desc->layers[0].nb_planes != 1) {
        LOGE("Unsupported DMA-BUF frame layout");
        return false;
    }

    const AVDRMPlaneDescriptor *p = &desc->layers[0].planes[0];
    struct sc_egl_dma_buf_plane plane = {
        .fd = desc->objects[0].fd,
        .offset = p->offset,
        .pitch = p->pitch,
        .modifier = desc->objects[0].format_modifier,
    };
    uint32_t drm_format =
        sc_interop_raw_get_opaque_drm_format(desc->layers[0].format);

    // Every frame comes with a fresh fd, but the inode identifies the DMA-BUF
    // itself (each has its own, for its lifetime)
    struct stat st;
    if (fstat(plane.fd, &st)) {
        LOGE("Could not identify the DMA-BUF: %s", strerror(errno));
        return false;
    }

    struct sc_size size = {frame->width, frame->height};

    struct sc_interop_raw_dma_buf *entry =
        sc_interop_raw_find_dma_buf(raw, st.st_dev, st.st_ino);
    if (entry && (entry->width != frame->width
                  || entry->height != frame->height
                  || entry->drm_format != drm_format
                  || entry->offset != plane.offset
                  || entry->pitch != plane.pitch
                  || entry->modifier != plane.modifier)) {
        LOGD("DMA-BUF %llu changed its layout, reimporting",
             (unsigned long long) st.st_ino);
        sc_interop_raw_release_dma_buf(raw, entry);
        entry = NULL;
    }

    if (entry) {
        ++raw->dma_buf_hits;
    } else {
        ++raw->dma_buf_misses;

        struct sc_interop *interop = &raw->interop;
        if (interop->texture && !raw->texture_is_dma_buf) {
            // The frames were in memory until now
            SDL_DestroyTexture(interop->texture);
            interop->texture = NULL;
        }

        // A new size means a new set of buffers: do not keep the old ones
        // alive (the fds pin their memory)
        for (size_t i = 0; i < ARRAY_LEN(raw->dma_bufs); ++i) {
            struct sc_interop_raw_dma_buf *old = &raw->dma_bufs[i];
            if (old->frame && (old->width != frame->width
                               || old->height != frame->height)) {
                sc_interop_raw_release_dma_buf(raw, old);
            }
        }

        entry = sc_interop_raw_get_free_dma_buf(raw);
        if (!sc_interop_raw_create_dma_buf(raw, entry, frame, st.st_dev,
                                           st.st_ino, drm_format, &plane)) {
            return false;
        }

        LOGD("DMA-BUF %llu imported (%" PRIu64 " hits, %" PRIu64 " misses)",
             (unsigned long long) st.st_ino, raw->dma_buf_hits,
             raw->dma_buf_misses);
    }

    entry->last_use = ++raw->dma_buf_clock;
    sc_interop_raw_show_texture(raw, entry->texture, size, true);

    uint64_t imports = raw->dma_buf_hits + raw->dma_buf_misses;
    if (imports % SC_INTEROP_RAW_DMA_BUF_STATS_PERIOD == 0) {
        unsigned cached = 0;
        for (size_t i = 0; i < ARRAY_LEN(raw->dma_bufs); ++i) {
            cached += raw->dma_bufs[i].frame != NULL;
        }
        LOGD("DMA-BUF cache: %" PRIu64 " hits, %" PRIu64 " misses, "
             "%u buffers cached", raw->dma_buf_hits, raw->dma_buf_misses,
             cached);
    }

    return true;
}

static bool
sc_interop_raw_import(struct sc_interop *interop, const AVFrame *frame) {
    struct sc_interop_raw *raw = DOWNCAST(interop);

    if (frame->format == AV_PIX_FMT_DRM_PRIME) {
        return sc_interop_raw_import_dma_buf(raw, frame);
    }

    SDL_PixelFormat format = sc_interop_raw_get_sdl_format(frame->format);
    if (format == SDL_PIXELFORMAT_UNKNOWN) {
        const char *name = av_get_pix_fmt_name(frame->format);
        LOGE("Unsupported raw frame format: %s", name ? name : "(unknown)");
        return false;
    }

    struct sc_size size = {frame->width, frame->height};
    if (!sc_interop_raw_ensure_texture(raw, size, format)) {
        return false;
    }

    if (!SDL_UpdateTexture(interop->texture, NULL, frame->data[0],
                           frame->linesize[0])) {
        LOGD("Could not update texture: %s", SDL_GetError());
        return false;
    }

    return true;
}

struct sc_interop_raw *
sc_interop_raw_new(SDL_Renderer *renderer, struct sc_opengl *gl) {
    struct sc_interop_raw *raw = malloc(sizeof(*raw));
    if (!raw) {
        LOG_OOM();
        return NULL;
    }

    raw->has_egl = gl && sc_egl_init(&raw->egl) && raw->egl.CreateImageKHR
                && raw->egl.has_dma_buf_import
                && raw->egl.EGLImageTargetTexture2DOES;
    if (!raw->has_egl) {
        LOGI("DMA-BUF frames unavailable (requires OpenGL and EGL DMA-BUF "
             "import)");
    }

    static const struct sc_interop_ops ops = {
        .import = sc_interop_raw_import,
        .reset = sc_interop_raw_reset,
        .destroy = sc_interop_raw_destroy,
    };

    raw->interop.name = "raw";
    raw->interop.hw_type = AV_HWDEVICE_TYPE_NONE;
    raw->interop.hw_device = NULL;
    // Several formats are accepted, checked on import
    raw->interop.pix_fmt = AV_PIX_FMT_NONE;
    raw->interop.texture = NULL;
    raw->interop.ops = &ops;

    raw->renderer = renderer;
    raw->gl = gl;
    raw->texture_is_dma_buf = false;
    raw->texture_format = SDL_PIXELFORMAT_UNKNOWN;
    memset(raw->dma_bufs, 0, sizeof(raw->dma_bufs));
    for (size_t i = 0; i < ARRAY_LEN(raw->dma_bufs); ++i) {
        raw->dma_bufs[i].image = EGL_NO_IMAGE_KHR;
    }
    raw->dma_buf_clock = 0;
    raw->dma_buf_hits = 0;
    raw->dma_buf_misses = 0;

    return raw;
}
