#ifndef SC_GL_EXTERNAL_COPY_H
#define SC_GL_EXTERNAL_COPY_H

#include "common.h"

#include <stdbool.h>

#include "egl.h"
#include "opengl.h"

/**
 * Copies an EGLImage that the driver only accepts as a GL_TEXTURE_EXTERNAL_OES
 * texture into an ordinary GL_TEXTURE_2D, with a shader through a framebuffer.
 *
 * NVIDIA's EGL imports a linear DMA-BUF (the guest's buffers in Venus mode)
 * only as an external texture, which the SDL renderer cannot draw. Every GL
 * state the copy touches is saved and restored, so the SDL renderer's view of
 * the context stays true.
 */
struct sc_gl_external_copy {
    bool initialized; // the functions and the program are ready
    bool failed; // initialization failed, do not retry

    unsigned program;
    int tex_location;
    unsigned framebuffer;
    unsigned vertex_buffer;

    struct sc_gl_external_copy_fns *fns;
};

void
sc_gl_external_copy_init(struct sc_gl_external_copy *copy);

void
sc_gl_external_copy_destroy(struct sc_gl_external_copy *copy);

// Creates an external texture whose storage is the EGLImage, or returns 0. The
// GL context must be current (the SDL renderer flushed).
unsigned
sc_gl_external_copy_create_texture(struct sc_gl_external_copy *copy,
                                   struct sc_opengl *gl, struct sc_egl *egl,
                                   EGLImageKHR image);

void
sc_gl_external_copy_destroy_texture(struct sc_gl_external_copy *copy,
                                    unsigned texture);

// Draws the external texture into the 2D texture (both width x height).
bool
sc_gl_external_copy_run(struct sc_gl_external_copy *copy, struct sc_opengl *gl,
                        unsigned external_texture, unsigned texture_2d,
                        int width, int height);

#endif
