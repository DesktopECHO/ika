#include "texture.h"

#include <assert.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
# include <sys/stat.h>
#endif
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <libavutil/pixfmt.h>

#include "util/log.h"

typedef void (*sc_gl_gen_textures_t)(GLsizei n, GLuint *textures);
typedef void (*sc_gl_delete_textures_t)(GLsizei n, const GLuint *textures);
typedef void (*sc_gl_gen_buffers_t)(GLsizei n, GLuint *buffers);
typedef void (*sc_gl_delete_buffers_t)(GLsizei n, const GLuint *buffers);
typedef void (*sc_gl_bind_buffer_t)(GLenum target, GLuint buffer);
typedef void (*sc_gl_buffer_data_t)(GLenum target, GLsizeiptr size,
                                    const void *data, GLenum usage);
typedef void *(*sc_gl_map_buffer_range_t)(GLenum target, GLintptr offset,
                                          GLsizeiptr length,
                                          GLbitfield access);
typedef GLboolean (*sc_gl_unmap_buffer_t)(GLenum target);
typedef void (*sc_gl_tex_sub_image_2d_t)(GLenum target, GLint level,
                                         GLint xoffset, GLint yoffset,
                                         GLsizei width, GLsizei height,
                                         GLenum format, GLenum type,
                                         const void *pixels);
typedef void (*sc_gl_egl_image_target_texture_2d_oes_t)(GLenum target,
                                                        GLeglImageOES image);

static void
sc_texture_destroy_raw_pbos(struct sc_texture *tex) {
    bool has_pbo = tex->raw_pbo_ids[0] || tex->raw_pbo_ids[1]
                || tex->raw_pbo_ids[2];
    if (!has_pbo) {
        return;
    }

    sc_gl_delete_buffers_t delete_buffers =
        (sc_gl_delete_buffers_t) SDL_GL_GetProcAddress("glDeleteBuffers");
    if (delete_buffers) {
        GLuint buffers[3] = {
            tex->raw_pbo_ids[0],
            tex->raw_pbo_ids[1],
            tex->raw_pbo_ids[2],
        };
        delete_buffers(3, buffers);
    }
    tex->raw_pbo_ids[0] = 0;
    tex->raw_pbo_ids[1] = 0;
    tex->raw_pbo_ids[2] = 0;
    tex->raw_pbo_index = 0;
    tex->raw_pbo_supported = false;
}

static void
sc_texture_destroy_dmabuf_cache_entry(
        struct sc_texture *tex,
        struct sc_dmabuf_texture_cache_entry *entry) {
    if (!entry->used) {
        return;
    }

    if (tex->texture == entry->texture) {
        tex->texture = NULL;
    }

    if (entry->texture) {
        SDL_DestroyTexture(entry->texture);
    }

    if (entry->egl_image) {
        PFNEGLDESTROYIMAGEKHRPROC destroy_image =
            (PFNEGLDESTROYIMAGEKHRPROC)
                SDL_EGL_GetProcAddress("eglDestroyImageKHR");
        if (destroy_image) {
            destroy_image((EGLDisplay) entry->egl_display,
                          (EGLImageKHR) entry->egl_image);
        }
    }

    if (entry->gl_texture) {
        sc_gl_delete_textures_t delete_textures =
            (sc_gl_delete_textures_t) SDL_GL_GetProcAddress("glDeleteTextures");
        if (delete_textures) {
            GLuint texture = entry->gl_texture;
            delete_textures(1, &texture);
        }
    }

    memset(entry, 0, sizeof(*entry));
}

static void
sc_texture_destroy_dmabuf_import(struct sc_texture *tex) {
    for (size_t i = 0; i < SC_DMABUF_TEXTURE_CACHE_SIZE; ++i) {
        sc_texture_destroy_dmabuf_cache_entry(tex, &tex->dmabuf_cache[i]);
    }
    if (tex->texture_type == SC_TEXTURE_TYPE_DMABUF_FRAME) {
        tex->texture = NULL;
    }
}

static void
sc_texture_destroy_active_non_dmabuf_texture(struct sc_texture *tex) {
    if (tex->texture && tex->texture_type != SC_TEXTURE_TYPE_DMABUF_FRAME) {
        SDL_DestroyTexture(tex->texture);
        tex->texture = NULL;
    }
    tex->raw_texture_id = 0;
}

static void
sc_texture_destroy_current_texture(struct sc_texture *tex) {
    if (tex->texture_type == SC_TEXTURE_TYPE_DMABUF_FRAME) {
        sc_texture_destroy_dmabuf_import(tex);
    } else {
        sc_texture_destroy_active_non_dmabuf_texture(tex);
    }
}

static void
sc_texture_set_nearest_scale(SDL_Texture *texture) {
    if (!SDL_SetTextureScaleMode(texture, SDL_SCALEMODE_NEAREST)) {
        LOGW("Could not set nearest texture scaling: %s", SDL_GetError());
    }
}

bool
sc_texture_init(struct sc_texture *tex, SDL_Renderer *renderer, bool mipmaps) {
    const char *renderer_name = SDL_GetRendererName(renderer);
    LOGI("Renderer: %s", renderer_name ? renderer_name : "(unknown)");

    tex->mipmaps = false;

    // starts with "opengl"
    bool use_opengl = renderer_name && !strncmp(renderer_name, "opengl", 6);
    if (use_opengl) {
        struct sc_opengl *gl = &tex->gl;
        sc_opengl_init(gl);

        LOGI("OpenGL version: %s", gl->version);

        if (mipmaps) {
            bool supports_mipmaps =
                sc_opengl_version_at_least(gl, 3, 0, /* OpenGL 3.0+ */
                                               2, 0  /* OpenGL ES 2.0+ */);
            if (supports_mipmaps) {
                LOGI("Trilinear filtering enabled");
                tex->mipmaps = true;
            } else {
                LOGW("Trilinear filtering disabled "
                     "(OpenGL 3.0+ or ES 2.0+ required)");
            }
        } else {
            LOGI("Trilinear filtering disabled");
        }
    } else if (mipmaps) {
        LOGD("Trilinear filtering disabled (not an OpenGL renderer)");
    }

    tex->renderer = renderer;
    tex->texture = NULL;
    tex->texture_size = (struct sc_size) {0, 0};
    tex->texture_type = SC_TEXTURE_TYPE_FRAME;
    tex->raw_format = SDL_PIXELFORMAT_UNKNOWN;
    tex->raw_texture_id = 0;
    tex->raw_pbo_ids[0] = 0;
    tex->raw_pbo_ids[1] = 0;
    tex->raw_pbo_ids[2] = 0;
    tex->raw_pbo_index = 0;
    tex->raw_pbo_supported = false;
    tex->raw_pbo_enabled = getenv("SCRCPY_CUTTLEFISH_RAW_PBO") != NULL;
    memset(tex->dmabuf_cache, 0, sizeof(tex->dmabuf_cache));
    tex->dmabuf_cache_generation = 0;
    return true;
}

void
sc_texture_destroy(struct sc_texture *tex) {
    sc_texture_destroy_current_texture(tex);
    sc_texture_destroy_dmabuf_import(tex);
    sc_texture_destroy_raw_pbos(tex);
}

static enum SDL_Colorspace
sc_texture_to_sdl_color_space(enum AVColorSpace color_space,
                              enum AVColorRange color_range) {
    bool full_range = color_range == AVCOL_RANGE_JPEG;

    switch (color_space) {
        case AVCOL_SPC_BT709:
        case AVCOL_SPC_RGB:
            return full_range ? SDL_COLORSPACE_BT709_FULL
                              : SDL_COLORSPACE_BT709_LIMITED;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:
            return full_range ? SDL_COLORSPACE_BT601_FULL
                              : SDL_COLORSPACE_BT601_LIMITED;
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL:
            return full_range ? SDL_COLORSPACE_BT2020_FULL
                              : SDL_COLORSPACE_BT2020_LIMITED;
        default:
            return SDL_COLORSPACE_JPEG;
    }
}

static SDL_Texture *
sc_texture_create_frame_texture(struct sc_texture *tex,
                                struct sc_size size,
                                enum AVColorSpace color_space,
                                enum AVColorRange color_range) {
    SDL_PropertiesID props = SDL_CreateProperties();
    if (!props) {
        return NULL;
    }

    enum SDL_Colorspace sdl_color_space =
        sc_texture_to_sdl_color_space(color_space, color_range);

    bool ok =
        SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER,
                              SDL_PIXELFORMAT_YV12);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_ACCESS_NUMBER,
                                SDL_TEXTUREACCESS_STREAMING);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER,
                                size.width);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER,
                                size.height);
    ok &= SDL_SetNumberProperty(props,
                                SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER,
                                sdl_color_space);

    if (!ok) {
        LOGE("Could not set texture properties");
        SDL_DestroyProperties(props);
        return NULL;
    }

    SDL_Renderer *renderer = tex->renderer;
    SDL_Texture *texture = SDL_CreateTextureWithProperties(renderer, props);
    SDL_DestroyProperties(props);
    if (!texture) {
        LOGD("Could not create texture: %s", SDL_GetError());
        return NULL;
    }

    if (tex->mipmaps) {
        struct sc_opengl *gl = &tex->gl;

        SDL_PropertiesID props = SDL_GetTextureProperties(texture);
        if (!props) {
            LOGE("Could not get texture properties: %s", SDL_GetError());
            SDL_DestroyTexture(texture);
            return NULL;
        }

        const char *renderer_name = SDL_GetRendererName(tex->renderer);
        const char *key = !renderer_name || !strcmp(renderer_name, "opengl")
                        ? SDL_PROP_TEXTURE_OPENGL_TEXTURE_NUMBER
                        : SDL_PROP_TEXTURE_OPENGLES2_TEXTURE_NUMBER;

        int64_t texture_id = SDL_GetNumberProperty(props, key, 0);
        SDL_DestroyProperties(props);
        if (!texture_id) {
            LOGE("Could not get texture id: %s", SDL_GetError());
            SDL_DestroyTexture(texture);
            return NULL;
        }

        assert(!(texture_id & ~0xFFFFFFFF)); // fits in uint32_t
        tex->texture_id = texture_id;
        gl->BindTexture(GL_TEXTURE_2D, tex->texture_id);

        // Enable trilinear filtering for downscaling
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                          GL_LINEAR_MIPMAP_LINEAR);
        gl->TexParameterf(GL_TEXTURE_2D, GL_TEXTURE_LOD_BIAS, -1.f);

        gl->BindTexture(GL_TEXTURE_2D, 0);
    }

    return texture;
}

bool
sc_texture_set_from_frame(struct sc_texture *tex, const AVFrame *frame) {

    struct sc_size size = {frame->width, frame->height};
    assert(size.width && size.height);

    if (!tex->texture
            || tex->texture_type != SC_TEXTURE_TYPE_FRAME
            || tex->texture_size.width != size.width
            || tex->texture_size.height != size.height) {
        // Incompatible texture, recreate it
        enum AVColorSpace color_space = frame->colorspace;
        enum AVColorRange color_range = frame->color_range;

        sc_texture_destroy_current_texture(tex);

        tex->texture = sc_texture_create_frame_texture(tex, size, color_space,
                                                       color_range);
        if (!tex->texture) {
            return false;
        }

        tex->texture_size = size;
        tex->texture_type = SC_TEXTURE_TYPE_FRAME;

        LOGI("Texture: %" PRIu16 "x%" PRIu16, size.width, size.height);
    }

    assert(tex->texture);
    assert(tex->texture_type == SC_TEXTURE_TYPE_FRAME);

    bool ok = SDL_UpdateYUVTexture(tex->texture, NULL,
                                   frame->data[0], frame->linesize[0],
                                   frame->data[1], frame->linesize[1],
                                   frame->data[2], frame->linesize[2]);
    if (!ok) {
        LOGD("Could not update texture: %s", SDL_GetError());
        return false;
    }

    if (tex->mipmaps) {
        assert(tex->texture_id);
        struct sc_opengl *gl = &tex->gl;

        gl->BindTexture(GL_TEXTURE_2D, tex->texture_id);
        gl->GenerateMipmap(GL_TEXTURE_2D);
        gl->BindTexture(GL_TEXTURE_2D, 0);
    }

    return true;
}

static bool
sc_texture_get_raw_gl_format(SDL_PixelFormat format, GLenum *gl_format) {
    switch (format) {
        case SDL_PIXELFORMAT_XRGB8888:
        case SDL_PIXELFORMAT_ARGB8888:
        case SDL_PIXELFORMAT_BGRX8888:
        case SDL_PIXELFORMAT_BGRA8888:
            *gl_format = GL_BGRA;
            return true;
        case SDL_PIXELFORMAT_XBGR8888:
        case SDL_PIXELFORMAT_ABGR8888:
        case SDL_PIXELFORMAT_RGBX8888:
        case SDL_PIXELFORMAT_RGBA8888:
            *gl_format = GL_RGBA;
            return true;
        default:
            return false;
    }
}

static bool
sc_texture_init_raw_pbos(struct sc_texture *tex) {
    if (!tex->raw_pbo_enabled) {
        return false;
    }

    if (tex->raw_pbo_supported) {
        return true;
    }

    const char *renderer_name = SDL_GetRendererName(tex->renderer);
    bool use_opengl = renderer_name && !strncmp(renderer_name, "opengl", 6);
    if (!use_opengl) {
        return false;
    }
    if (!sc_opengl_version_at_least(&tex->gl, 3, 0, 3, 0)) {
        return false;
    }

    sc_gl_gen_buffers_t gen_buffers =
        (sc_gl_gen_buffers_t) SDL_GL_GetProcAddress("glGenBuffers");
    sc_gl_bind_buffer_t bind_buffer =
        (sc_gl_bind_buffer_t) SDL_GL_GetProcAddress("glBindBuffer");
    sc_gl_buffer_data_t buffer_data =
        (sc_gl_buffer_data_t) SDL_GL_GetProcAddress("glBufferData");
    sc_gl_map_buffer_range_t map_buffer_range =
        (sc_gl_map_buffer_range_t) SDL_GL_GetProcAddress("glMapBufferRange");
    sc_gl_unmap_buffer_t unmap_buffer =
        (sc_gl_unmap_buffer_t) SDL_GL_GetProcAddress("glUnmapBuffer");
    sc_gl_tex_sub_image_2d_t tex_sub_image_2d =
        (sc_gl_tex_sub_image_2d_t) SDL_GL_GetProcAddress("glTexSubImage2D");
    if (!gen_buffers || !bind_buffer || !buffer_data || !map_buffer_range
            || !unmap_buffer || !tex_sub_image_2d) {
        return false;
    }

    GLuint buffers[3] = {};
    gen_buffers(3, buffers);
    if (!buffers[0] || !buffers[1] || !buffers[2]) {
        if (buffers[0] || buffers[1] || buffers[2]) {
            sc_gl_delete_buffers_t delete_buffers =
                (sc_gl_delete_buffers_t)
                    SDL_GL_GetProcAddress("glDeleteBuffers");
            if (delete_buffers) {
                delete_buffers(3, buffers);
            }
        }
        return false;
    }

    tex->raw_pbo_ids[0] = buffers[0];
    tex->raw_pbo_ids[1] = buffers[1];
    tex->raw_pbo_ids[2] = buffers[2];
    tex->raw_pbo_index = 0;
    tex->raw_pbo_supported = true;
    LOGI("Raw texture PBO upload enabled");
    return true;
}

static bool
sc_texture_upload_raw_pbo(struct sc_texture *tex, struct sc_size size,
                          SDL_PixelFormat format, const uint8_t *pixels,
                          uint32_t stride) {
    if (!tex->raw_texture_id || !sc_texture_init_raw_pbos(tex)) {
        return false;
    }

    GLenum gl_format;
    if (!sc_texture_get_raw_gl_format(format, &gl_format)) {
        return false;
    }

    uint32_t bpp = SDL_BYTESPERPIXEL(format);
    if (bpp != 4) {
        return false;
    }

    size_t row_size = (size_t) size.width * bpp;
    size_t upload_size = row_size * size.height;
    if (upload_size > (size_t) PTRDIFF_MAX) {
        return false;
    }

    sc_gl_bind_buffer_t bind_buffer =
        (sc_gl_bind_buffer_t) SDL_GL_GetProcAddress("glBindBuffer");
    sc_gl_buffer_data_t buffer_data =
        (sc_gl_buffer_data_t) SDL_GL_GetProcAddress("glBufferData");
    sc_gl_map_buffer_range_t map_buffer_range =
        (sc_gl_map_buffer_range_t) SDL_GL_GetProcAddress("glMapBufferRange");
    sc_gl_unmap_buffer_t unmap_buffer =
        (sc_gl_unmap_buffer_t) SDL_GL_GetProcAddress("glUnmapBuffer");
    sc_gl_tex_sub_image_2d_t tex_sub_image_2d =
        (sc_gl_tex_sub_image_2d_t) SDL_GL_GetProcAddress("glTexSubImage2D");
    if (!bind_buffer || !buffer_data || !map_buffer_range || !unmap_buffer
            || !tex_sub_image_2d) {
        return false;
    }

    GLuint pbo = tex->raw_pbo_ids[tex->raw_pbo_index++ % 3];
    bind_buffer(GL_PIXEL_UNPACK_BUFFER, pbo);
    buffer_data(GL_PIXEL_UNPACK_BUFFER, upload_size, NULL, GL_STREAM_DRAW);

    uint8_t *mapped =
        map_buffer_range(GL_PIXEL_UNPACK_BUFFER, 0, upload_size,
                         GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
    if (!mapped) {
        bind_buffer(GL_PIXEL_UNPACK_BUFFER, 0);
        return false;
    }

    if (stride == row_size) {
        memcpy(mapped, pixels, upload_size);
    } else {
        for (uint32_t y = 0; y < size.height; ++y) {
            memcpy(mapped + y * row_size, pixels + (size_t) y * stride,
                   row_size);
        }
    }

    if (!unmap_buffer(GL_PIXEL_UNPACK_BUFFER)) {
        bind_buffer(GL_PIXEL_UNPACK_BUFFER, 0);
        return false;
    }

    tex->gl.BindTexture(GL_TEXTURE_2D, tex->raw_texture_id);
    tex_sub_image_2d(GL_TEXTURE_2D, 0, 0, 0, size.width, size.height,
                     gl_format, GL_UNSIGNED_BYTE, NULL);
    tex->gl.BindTexture(GL_TEXTURE_2D, 0);
    bind_buffer(GL_PIXEL_UNPACK_BUFFER, 0);
    return true;
}

bool
sc_texture_set_from_raw_frame(struct sc_texture *tex, struct sc_size size,
                              SDL_PixelFormat format, const uint8_t *pixels,
                              uint32_t stride) {
    assert(size.width && size.height);
    assert(pixels);
    assert(stride);
    assert(format != SDL_PIXELFORMAT_UNKNOWN);

    if (!SDL_GetPixelFormatDetails(format)) {
        LOGE("Unsupported raw frame pixel format: %" PRIu32, format);
        return false;
    }

    if (!tex->texture
            || tex->texture_type != SC_TEXTURE_TYPE_RAW_FRAME
            || tex->texture_size.width != size.width
            || tex->texture_size.height != size.height
            || tex->raw_format != format) {
        sc_texture_destroy_current_texture(tex);

        tex->texture = SDL_CreateTexture(tex->renderer, format,
                                         SDL_TEXTUREACCESS_STREAMING,
                                         size.width, size.height);
        if (!tex->texture) {
            LOGD("Could not create raw frame texture: %s", SDL_GetError());
            return false;
        }
        sc_texture_set_nearest_scale(tex->texture);

        tex->texture_size = size;
        tex->texture_type = SC_TEXTURE_TYPE_RAW_FRAME;
        tex->raw_format = format;
        tex->raw_texture_id = 0;

        const char *renderer_name = SDL_GetRendererName(tex->renderer);
        bool use_opengl = renderer_name && !strncmp(renderer_name, "opengl", 6);
        if (use_opengl) {
            SDL_PropertiesID props = SDL_GetTextureProperties(tex->texture);
            if (props) {
                const char *key = !strcmp(renderer_name, "opengl")
                                ? SDL_PROP_TEXTURE_OPENGL_TEXTURE_NUMBER
                                : SDL_PROP_TEXTURE_OPENGLES2_TEXTURE_NUMBER;
                int64_t texture_id = SDL_GetNumberProperty(props, key, 0);
                SDL_DestroyProperties(props);
                if (texture_id && !(texture_id & ~0xFFFFFFFF)) {
                    tex->raw_texture_id = texture_id;
                }
            }
        }

        LOGI("Raw texture: %" PRIu16 "x%" PRIu16, size.width, size.height);
    }

    assert(tex->texture);
    assert(tex->texture_type == SC_TEXTURE_TYPE_RAW_FRAME);

    bool ok = sc_texture_upload_raw_pbo(tex, size, format, pixels, stride);
    if (ok) {
        return true;
    }

    ok = SDL_UpdateTexture(tex->texture, NULL, pixels, stride);
    if (!ok) {
        LOGD("Could not update raw texture: %s", SDL_GetError());
        return false;
    }

    return true;
}

static bool
sc_texture_get_dmabuf_cache_key(
        int dmabuf_fd, struct sc_size size, uint32_t fourcc,
        SDL_PixelFormat format, uint32_t offset, uint32_t stride,
        uint32_t modifier_hi, uint32_t modifier_lo,
        struct sc_dmabuf_texture_cache_entry *key) {
#ifdef _WIN32
    (void) dmabuf_fd;
    (void) size;
    (void) fourcc;
    (void) format;
    (void) offset;
    (void) stride;
    (void) modifier_hi;
    (void) modifier_lo;
    (void) key;
    return false;
#else
    struct stat st;
    if (fstat(dmabuf_fd, &st)) {
        LOGD("Could not stat DMA-BUF fd");
        return false;
    }

    memset(key, 0, sizeof(*key));
    key->dev = st.st_dev;
    key->ino = st.st_ino;
    key->size = size;
    key->fourcc = fourcc;
    key->format = format;
    key->offset = offset;
    key->stride = stride;
    key->modifier_hi = modifier_hi;
    key->modifier_lo = modifier_lo;
    return true;
#endif
}

static bool
sc_texture_dmabuf_cache_entry_matches(
        const struct sc_dmabuf_texture_cache_entry *entry,
        const struct sc_dmabuf_texture_cache_entry *key) {
    return entry->used
        && entry->dev == key->dev
        && entry->ino == key->ino
        && entry->size.width == key->size.width
        && entry->size.height == key->size.height
        && entry->fourcc == key->fourcc
        && entry->format == key->format
        && entry->offset == key->offset
        && entry->stride == key->stride
        && entry->modifier_hi == key->modifier_hi
        && entry->modifier_lo == key->modifier_lo;
}

static struct sc_dmabuf_texture_cache_entry *
sc_texture_find_dmabuf_cache_entry(
        struct sc_texture *tex,
        const struct sc_dmabuf_texture_cache_entry *key) {
    for (size_t i = 0; i < SC_DMABUF_TEXTURE_CACHE_SIZE; ++i) {
        struct sc_dmabuf_texture_cache_entry *entry = &tex->dmabuf_cache[i];
        if (sc_texture_dmabuf_cache_entry_matches(entry, key)) {
            return entry;
        }
    }

    return NULL;
}

static struct sc_dmabuf_texture_cache_entry *
sc_texture_get_dmabuf_cache_slot(struct sc_texture *tex) {
    struct sc_dmabuf_texture_cache_entry *oldest = &tex->dmabuf_cache[0];

    for (size_t i = 0; i < SC_DMABUF_TEXTURE_CACHE_SIZE; ++i) {
        struct sc_dmabuf_texture_cache_entry *entry = &tex->dmabuf_cache[i];
        if (!entry->used) {
            return entry;
        }
        if (entry->last_used < oldest->last_used) {
            oldest = entry;
        }
    }

    sc_texture_destroy_dmabuf_cache_entry(tex, oldest);
    return oldest;
}

static void
sc_texture_activate_dmabuf_cache_entry(
        struct sc_texture *tex,
        struct sc_dmabuf_texture_cache_entry *entry) {
    sc_texture_destroy_active_non_dmabuf_texture(tex);

    entry->last_used = ++tex->dmabuf_cache_generation;
    tex->texture = entry->texture;
    tex->texture_size = entry->size;
    tex->texture_type = SC_TEXTURE_TYPE_DMABUF_FRAME;
    tex->raw_format = entry->format;
}

static void
sc_texture_destroy_dmabuf_temp_import(EGLDisplay display, EGLImageKHR image,
                                      GLuint gl_texture) {
    if (gl_texture) {
        sc_gl_delete_textures_t delete_textures =
            (sc_gl_delete_textures_t) SDL_GL_GetProcAddress("glDeleteTextures");
        if (delete_textures) {
            delete_textures(1, &gl_texture);
        }
    }

    if (image && image != EGL_NO_IMAGE_KHR) {
        PFNEGLDESTROYIMAGEKHRPROC destroy_image =
            (PFNEGLDESTROYIMAGEKHRPROC)
                SDL_EGL_GetProcAddress("eglDestroyImageKHR");
        if (destroy_image) {
            destroy_image(display, image);
        }
    }
}

bool
sc_texture_set_from_dmabuf_frame(struct sc_texture *tex, struct sc_size size,
                                 uint32_t fourcc, SDL_PixelFormat format,
                                 int dmabuf_fd, uint32_t offset,
                                 uint32_t stride, uint32_t modifier_hi,
                                 uint32_t modifier_lo) {
    assert(size.width && size.height);
    assert(dmabuf_fd >= 0);
    assert(stride);

    struct sc_dmabuf_texture_cache_entry key;
    if (!sc_texture_get_dmabuf_cache_key(dmabuf_fd, size, fourcc, format,
                                         offset, stride, modifier_hi,
                                         modifier_lo, &key)) {
        return false;
    }

    struct sc_dmabuf_texture_cache_entry *cached =
        sc_texture_find_dmabuf_cache_entry(tex, &key);
    if (cached) {
        sc_texture_activate_dmabuf_cache_entry(tex, cached);
        LOGV("DMA-BUF texture cache hit: %" PRIu16 "x%" PRIu16,
             size.width, size.height);
        return true;
    }

    const char *renderer_name = SDL_GetRendererName(tex->renderer);
    bool use_opengl = renderer_name && !strncmp(renderer_name, "opengl", 6);
    if (!use_opengl) {
        LOGD("DMA-BUF import requires the SDL OpenGL renderer");
        return false;
    }

    EGLDisplay display = (EGLDisplay) SDL_EGL_GetCurrentDisplay();
    if (!display) {
        LOGD("No current EGL display for DMA-BUF import: %s", SDL_GetError());
        return false;
    }

    PFNEGLCREATEIMAGEKHRPROC create_image =
        (PFNEGLCREATEIMAGEKHRPROC) SDL_EGL_GetProcAddress("eglCreateImageKHR");
    sc_gl_egl_image_target_texture_2d_oes_t image_target_texture =
        (sc_gl_egl_image_target_texture_2d_oes_t)
            SDL_GL_GetProcAddress("glEGLImageTargetTexture2DOES");
    sc_gl_gen_textures_t gen_textures =
        (sc_gl_gen_textures_t) SDL_GL_GetProcAddress("glGenTextures");
    if (!create_image || !image_target_texture || !gen_textures) {
        LOGD("Missing EGL/GL DMA-BUF import entry points");
        return false;
    }

    EGLint attrs[17];
    size_t i = 0;
    attrs[i++] = EGL_WIDTH;
    attrs[i++] = size.width;
    attrs[i++] = EGL_HEIGHT;
    attrs[i++] = size.height;
    attrs[i++] = EGL_LINUX_DRM_FOURCC_EXT;
    attrs[i++] = fourcc;
    attrs[i++] = EGL_DMA_BUF_PLANE0_FD_EXT;
    attrs[i++] = dmabuf_fd;
    attrs[i++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT;
    attrs[i++] = offset;
    attrs[i++] = EGL_DMA_BUF_PLANE0_PITCH_EXT;
    attrs[i++] = stride;

    if (modifier_hi || modifier_lo) {
        attrs[i++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
        attrs[i++] = modifier_hi;
        attrs[i++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
        attrs[i++] = modifier_lo;
    }
    attrs[i++] = EGL_NONE;

    EGLImageKHR image =
        create_image(display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL,
                     attrs);
    if (image == EGL_NO_IMAGE_KHR) {
        LOGD("Could not import DMA-BUF as EGLImage");
        return false;
    }

    GLuint gl_texture = 0;
    gen_textures(1, &gl_texture);
    if (!gl_texture) {
        sc_texture_destroy_dmabuf_temp_import(display, image, 0);
        return false;
    }

    tex->gl.BindTexture(GL_TEXTURE_2D, gl_texture);
    tex->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    tex->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    tex->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    tex->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    image_target_texture(GL_TEXTURE_2D, (GLeglImageOES) image);
    tex->gl.BindTexture(GL_TEXTURE_2D, 0);

    SDL_PropertiesID props = SDL_CreateProperties();
    if (!props) {
        sc_texture_destroy_dmabuf_temp_import(display, image, gl_texture);
        return false;
    }

    bool ok =
        SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER,
                              format);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_ACCESS_NUMBER,
                                SDL_TEXTUREACCESS_STATIC);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER,
                                size.width);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER,
                                size.height);
    const char *texture_prop = !strcmp(renderer_name, "opengl")
                             ? SDL_PROP_TEXTURE_CREATE_OPENGL_TEXTURE_NUMBER
                             : SDL_PROP_TEXTURE_CREATE_OPENGLES2_TEXTURE_NUMBER;
    ok &= SDL_SetNumberProperty(props, texture_prop, gl_texture);

    if (!ok) {
        SDL_DestroyProperties(props);
        sc_texture_destroy_dmabuf_temp_import(display, image, gl_texture);
        return false;
    }

    SDL_Texture *texture =
        SDL_CreateTextureWithProperties(tex->renderer, props);
    SDL_DestroyProperties(props);
    if (!texture) {
        LOGD("Could not wrap DMA-BUF GL texture: %s", SDL_GetError());
        sc_texture_destroy_dmabuf_temp_import(display, image, gl_texture);
        return false;
    }
    sc_texture_set_nearest_scale(texture);

    struct sc_dmabuf_texture_cache_entry *entry =
        sc_texture_get_dmabuf_cache_slot(tex);
    *entry = key;
    entry->used = true;
    entry->gl_texture = gl_texture;
    entry->egl_image = image;
    entry->egl_display = display;
    entry->texture = texture;

    sc_texture_activate_dmabuf_cache_entry(tex, entry);

    LOGD("DMA-BUF texture imported: %" PRIu16 "x%" PRIu16,
         size.width, size.height);
    return true;
}

bool
sc_texture_set_from_surface(struct sc_texture *tex, SDL_Surface *surface) {
    sc_texture_destroy_current_texture(tex);
    sc_texture_destroy_dmabuf_import(tex);

    tex->texture = SDL_CreateTextureFromSurface(tex->renderer, surface);
    if (!tex->texture) {
        LOGE("Could not create texture: %s", SDL_GetError());
        return false;
    }

    tex->texture_size.width = surface->w;
    tex->texture_size.height = surface->h;
    tex->texture_type = SC_TEXTURE_TYPE_ICON;

    return true;
}

void
sc_texture_reset(struct sc_texture *tex) {
    sc_texture_destroy_current_texture(tex);
    sc_texture_destroy_dmabuf_import(tex);
}
