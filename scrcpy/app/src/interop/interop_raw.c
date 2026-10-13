#include "interop_raw.h"

#include <assert.h>
#include <inttypes.h>
#include <stdlib.h>

#include <libavutil/hwcontext_drm.h>
#include <libavutil/pixdesc.h>

#include "util/log.h"

/** Downcast interop to sc_interop_raw */
#define DOWNCAST(INTEROP) \
    container_of(INTEROP, struct sc_interop_raw, interop)

#define SC_FOURCC(a, b, c, d) \
    ((uint32_t) (a) | ((uint32_t) (b) << 8) | ((uint32_t) (c) << 16) \
        | ((uint32_t) (d) << 24))

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
sc_interop_raw_release_dma_buf(struct sc_interop_raw *raw) {
    if (raw->image != EGL_NO_IMAGE_KHR) {
        sc_egl_destroy_image(&raw->egl, raw->image);
        raw->image = EGL_NO_IMAGE_KHR;
    }
    av_frame_free(&raw->dma_buf_frame);
}

static void
sc_interop_raw_reset(struct sc_interop *interop) {
    struct sc_interop_raw *raw = DOWNCAST(interop);
    if (interop->texture) {
        sc_interop_raw_release_dma_buf(raw);
        SDL_DestroyTexture(interop->texture);
        interop->texture = NULL;
    }
}

static void
sc_interop_raw_destroy(struct sc_interop *interop) {
    sc_interop_raw_reset(interop);
}

static bool
sc_interop_raw_create_texture(struct sc_interop_raw *raw, struct sc_size size,
                              SDL_PixelFormat format, bool dma_buf) {
    SDL_Texture *texture = SDL_CreateTexture(raw->renderer, format,
                                             SDL_TEXTUREACCESS_STATIC,
                                             size.width, size.height);
    if (!texture) {
        LOGE("Could not create texture: %s", SDL_GetError());
        return false;
    }

    if (dma_buf) {
        SDL_PropertiesID props = SDL_GetTextureProperties(texture);
        const char *key = raw->gl->is_opengles
                        ? SDL_PROP_TEXTURE_OPENGLES2_TEXTURE_NUMBER
                        : SDL_PROP_TEXTURE_OPENGL_TEXTURE_NUMBER;
        int64_t texture_id = props ? SDL_GetNumberProperty(props, key, 0) : 0;
        if (!texture_id) {
            LOGE("Could not get texture id: %s", SDL_GetError());
            SDL_DestroyTexture(texture);
            return false;
        }
        assert(!(texture_id & ~0xFFFFFFFF)); // fits in uint32_t
        raw->texture_id = texture_id;
    }

    raw->interop.texture = texture;
    raw->interop.frame_size = size;
    raw->texture_format = format;
    raw->texture_is_dma_buf = dma_buf;
    LOGI("Texture (%s): %" PRIu16 "x%" PRIu16, dma_buf ? "DMA-BUF" : "raw",
         size.width, size.height);
    return true;
}

static bool
sc_interop_raw_ensure_texture(struct sc_interop_raw *raw, struct sc_size size,
                              SDL_PixelFormat format, bool dma_buf) {
    struct sc_interop *interop = &raw->interop;
    if (interop->texture
            && interop->frame_size.width == size.width
            && interop->frame_size.height == size.height
            && raw->texture_format == format
            && raw->texture_is_dma_buf == dma_buf) {
        return true;
    }

    sc_interop_raw_reset(interop);
    return sc_interop_raw_create_texture(raw, size, format, dma_buf);
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

    struct sc_size size = {frame->width, frame->height};
    // The EGLImage replaces the texture storage, the format only tells SDL to
    // sample it without swizzling
    if (!sc_interop_raw_ensure_texture(raw, size, SDL_PIXELFORMAT_RGBA32,
                                       true)) {
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
    EGLImageKHR image =
        sc_egl_create_image_dma_buf(&raw->egl, drm_format, frame->width,
                                    frame->height, &plane);
    if (image == EGL_NO_IMAGE_KHR) {
        LOGE("Could not import DMA-BUF as EGLImage (EGL error %#x)",
             raw->egl.GetError());
        return false;
    }

    // Invalidate the SDL OpenGL cache before touching the texture behind its
    // back
    if (!SDL_FlushRenderer(raw->renderer)) {
        LOGD("Could not flush renderer before DMA-BUF import: %s",
             SDL_GetError());
    }

    struct sc_opengl *gl = raw->gl;
    while (gl->GetError()); // Clear any errors left
    gl->BindTexture(GL_TEXTURE_2D, raw->texture_id);
    raw->egl.EGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);
    gl->BindTexture(GL_TEXTURE_2D, 0);
    GLenum gl_error = gl->GetError();
    if (gl_error) {
        LOGE("Could not attach the EGLImage to the texture (GL error %#x)",
             gl_error);
        sc_egl_destroy_image(&raw->egl, image);
        return false;
    }

    AVFrame *ref = av_frame_clone(frame);
    if (!ref) {
        LOG_OOM();
        sc_egl_destroy_image(&raw->egl, image);
        return false;
    }

    // Release the previous buffer only once the new one is attached
    sc_interop_raw_release_dma_buf(raw);
    raw->image = image;
    raw->dma_buf_frame = ref;
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
    if (!sc_interop_raw_ensure_texture(raw, size, format, false)) {
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
    raw->texture_id = 0;
    raw->image = EGL_NO_IMAGE_KHR;
    raw->dma_buf_frame = NULL;

    return raw;
}
