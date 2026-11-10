#include "gl_external_copy.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <SDL3/SDL.h>

#include "util/log.h"

// From GL_OES_EGL_image_external, only defined by the OpenGL ES headers
#ifndef GL_TEXTURE_EXTERNAL_OES
# define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif
#ifndef GL_TEXTURE_BINDING_EXTERNAL_OES
# define GL_TEXTURE_BINDING_EXTERNAL_OES 0x8D67
#endif

struct sc_gl_external_copy_fns {
    // OpenGL 1.1, which has no PFN types in glext.h
    void (APIENTRY *GenTextures)(GLsizei n, GLuint *textures);
    void (APIENTRY *DeleteTextures)(GLsizei n, const GLuint *textures);
    PFNGLGENFRAMEBUFFERSPROC GenFramebuffers;
    PFNGLDELETEFRAMEBUFFERSPROC DeleteFramebuffers;
    PFNGLBINDFRAMEBUFFERPROC BindFramebuffer;
    PFNGLFRAMEBUFFERTEXTURE2DPROC FramebufferTexture2D;
    PFNGLCHECKFRAMEBUFFERSTATUSPROC CheckFramebufferStatus;
    PFNGLCREATESHADERPROC CreateShader;
    PFNGLSHADERSOURCEPROC ShaderSource;
    PFNGLCOMPILESHADERPROC CompileShader;
    PFNGLGETSHADERIVPROC GetShaderiv;
    PFNGLGETSHADERINFOLOGPROC GetShaderInfoLog;
    PFNGLDELETESHADERPROC DeleteShader;
    PFNGLCREATEPROGRAMPROC CreateProgram;
    PFNGLATTACHSHADERPROC AttachShader;
    PFNGLBINDATTRIBLOCATIONPROC BindAttribLocation;
    PFNGLLINKPROGRAMPROC LinkProgram;
    PFNGLGETPROGRAMIVPROC GetProgramiv;
    PFNGLGETPROGRAMINFOLOGPROC GetProgramInfoLog;
    PFNGLDELETEPROGRAMPROC DeleteProgram;
    PFNGLUSEPROGRAMPROC UseProgram;
    PFNGLGETUNIFORMLOCATIONPROC GetUniformLocation;
    PFNGLUNIFORM1IPROC Uniform1i;
    PFNGLACTIVETEXTUREPROC ActiveTexture;
    PFNGLGENBUFFERSPROC GenBuffers;
    PFNGLDELETEBUFFERSPROC DeleteBuffers;
    PFNGLBINDBUFFERPROC BindBuffer;
    PFNGLBUFFERDATAPROC BufferData;
    PFNGLENABLEVERTEXATTRIBARRAYPROC EnableVertexAttribArray;
    PFNGLDISABLEVERTEXATTRIBARRAYPROC DisableVertexAttribArray;
    PFNGLVERTEXATTRIBPOINTERPROC VertexAttribPointer;
    PFNGLGETVERTEXATTRIBIVPROC GetVertexAttribiv;
    PFNGLGETVERTEXATTRIBPOINTERVPROC GetVertexAttribPointerv;
    void (APIENTRY *GetIntegerv)(GLenum pname, GLint *params);
    GLboolean (APIENTRY *IsEnabled)(GLenum cap);
    void (APIENTRY *Enable)(GLenum cap);
    void (APIENTRY *Disable)(GLenum cap);
    void (APIENTRY *Viewport)(GLint x, GLint y, GLsizei w, GLsizei h);
    void (APIENTRY *DrawArrays)(GLenum mode, GLint first, GLsizei count);
};

static bool
sc_gl_external_copy_load(struct sc_gl_external_copy_fns *f) {
#define LOAD(NAME) \
    f->NAME = (void *) SDL_GL_GetProcAddress("gl" #NAME); \
    if (!f->NAME) { \
        LOGW("OpenGL function gl" #NAME " unavailable"); \
        return false; \
    }
    LOAD(GenTextures);
    LOAD(DeleteTextures);
    LOAD(GenFramebuffers);
    LOAD(DeleteFramebuffers);
    LOAD(BindFramebuffer);
    LOAD(FramebufferTexture2D);
    LOAD(CheckFramebufferStatus);
    LOAD(CreateShader);
    LOAD(ShaderSource);
    LOAD(CompileShader);
    LOAD(GetShaderiv);
    LOAD(GetShaderInfoLog);
    LOAD(DeleteShader);
    LOAD(CreateProgram);
    LOAD(AttachShader);
    LOAD(BindAttribLocation);
    LOAD(LinkProgram);
    LOAD(GetProgramiv);
    LOAD(GetProgramInfoLog);
    LOAD(DeleteProgram);
    LOAD(UseProgram);
    LOAD(GetUniformLocation);
    LOAD(Uniform1i);
    LOAD(ActiveTexture);
    LOAD(GenBuffers);
    LOAD(DeleteBuffers);
    LOAD(BindBuffer);
    LOAD(BufferData);
    LOAD(EnableVertexAttribArray);
    LOAD(DisableVertexAttribArray);
    LOAD(VertexAttribPointer);
    LOAD(GetVertexAttribiv);
    LOAD(GetVertexAttribPointerv);
    LOAD(GetIntegerv);
    LOAD(IsEnabled);
    LOAD(Enable);
    LOAD(Disable);
    LOAD(Viewport);
    LOAD(DrawArrays);
#undef LOAD
    return true;
}

static unsigned
sc_gl_external_copy_compile(struct sc_gl_external_copy_fns *f, GLenum type,
                            const char *source) {
    GLuint shader = f->CreateShader(type);
    if (!shader) {
        return 0;
    }
    f->ShaderSource(shader, 1, &source, NULL);
    f->CompileShader(shader);
    GLint ok = 0;
    f->GetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512] = "";
        f->GetShaderInfoLog(shader, sizeof(log), NULL, log);
        LOGW("Could not compile the external texture shader: %s", log);
        f->DeleteShader(shader);
        return 0;
    }
    return shader;
}

// The quad covers the viewport, and texture row 0 is the top of the image
// (the first row of the DMA-BUF): fragment row y of the framebuffer, which is
// row y of the destination texture, samples row y of the source
static const char *const SC_VERTEX_SHADER_BODY =
    "attribute vec2 position;\n"
    "varying vec2 coord;\n"
    "void main() {\n"
    "    coord = position * 0.5 + 0.5;\n"
    "    gl_Position = vec4(position, 0.0, 1.0);\n"
    "}\n";

static const char *const SC_FRAGMENT_SHADER_BODY =
    "uniform samplerExternalOES tex;\n"
    "varying vec2 coord;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(tex, coord);\n"
    "}\n";

static bool
sc_gl_external_copy_setup(struct sc_gl_external_copy *copy,
                          struct sc_opengl *gl) {
    struct sc_gl_external_copy_fns *f = malloc(sizeof(*f));
    if (!f) {
        LOG_OOM();
        return false;
    }
    copy->fns = f;
    if (!sc_gl_external_copy_load(f)) {
        return false;
    }

    // OpenGL ES 2 and OpenGL 2.1 (the SDL renderers' contexts)
    const char *vs_header = gl->is_opengles
                          ? "#version 100\n"
                          : "#version 110\n";
    const char *fs_header = gl->is_opengles
                          ? "#version 100\n"
                            "#extension GL_OES_EGL_image_external : require\n"
                            "precision mediump float;\n"
                          : "#version 110\n"
                            "#extension GL_OES_EGL_image_external : require\n";
    char vs[512];
    char fs[512];
    int r = snprintf(vs, sizeof(vs), "%s%s", vs_header, SC_VERTEX_SHADER_BODY);
    assert(r > 0 && (size_t) r < sizeof(vs));
    r = snprintf(fs, sizeof(fs), "%s%s", fs_header, SC_FRAGMENT_SHADER_BODY);
    assert(r > 0 && (size_t) r < sizeof(fs));
    (void) r;

    GLuint vertex = sc_gl_external_copy_compile(f, GL_VERTEX_SHADER, vs);
    GLuint fragment = sc_gl_external_copy_compile(f, GL_FRAGMENT_SHADER, fs);
    if (!vertex || !fragment) {
        if (vertex) {
            f->DeleteShader(vertex);
        }
        if (fragment) {
            f->DeleteShader(fragment);
        }
        return false;
    }

    GLuint program = f->CreateProgram();
    f->AttachShader(program, vertex);
    f->AttachShader(program, fragment);
    f->BindAttribLocation(program, 0, "position");
    f->LinkProgram(program);
    f->DeleteShader(vertex);
    f->DeleteShader(fragment);
    GLint ok = 0;
    f->GetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = "";
        f->GetProgramInfoLog(program, sizeof(log), NULL, log);
        LOGW("Could not link the external texture shader: %s", log);
        f->DeleteProgram(program);
        return false;
    }
    copy->program = program;
    copy->tex_location = f->GetUniformLocation(program, "tex");

    GLint saved_buffer = 0;
    f->GetIntegerv(GL_ARRAY_BUFFER_BINDING, &saved_buffer);
    static const GLfloat quad[] = {-1.f, -1.f, 1.f, -1.f, -1.f, 1.f, 1.f, 1.f};
    GLuint vertex_buffer;
    f->GenBuffers(1, &vertex_buffer);
    f->BindBuffer(GL_ARRAY_BUFFER, vertex_buffer);
    f->BufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    f->BindBuffer(GL_ARRAY_BUFFER, (GLuint) saved_buffer);
    copy->vertex_buffer = vertex_buffer;

    GLuint framebuffer;
    f->GenFramebuffers(1, &framebuffer);
    copy->framebuffer = framebuffer;

    GLenum error = gl->GetError();
    if (error) {
        LOGW("Could not set up the external texture copy (GL error %#x)",
             error);
        return false;
    }
    return true;
}

void
sc_gl_external_copy_init(struct sc_gl_external_copy *copy) {
    copy->initialized = false;
    copy->failed = false;
    copy->program = 0;
    copy->tex_location = -1;
    copy->framebuffer = 0;
    copy->vertex_buffer = 0;
    copy->fns = NULL;
}

static bool
sc_gl_external_copy_ensure(struct sc_gl_external_copy *copy,
                           struct sc_opengl *gl) {
    if (copy->initialized) {
        return true;
    }
    if (copy->failed) {
        return false;
    }
    if (!sc_gl_external_copy_setup(copy, gl)) {
        copy->failed = true;
        return false;
    }
    copy->initialized = true;
    return true;
}

void
sc_gl_external_copy_destroy(struct sc_gl_external_copy *copy) {
    struct sc_gl_external_copy_fns *f = copy->fns;
    if (copy->initialized) {
        f->DeleteFramebuffers(1, &copy->framebuffer);
        f->DeleteBuffers(1, &copy->vertex_buffer);
        f->DeleteProgram(copy->program);
    }
    free(f);
    sc_gl_external_copy_init(copy);
}

unsigned
sc_gl_external_copy_create_texture(struct sc_gl_external_copy *copy,
                                   struct sc_opengl *gl, struct sc_egl *egl,
                                   EGLImageKHR image) {
    if (!sc_gl_external_copy_ensure(copy, gl)) {
        return 0;
    }
    struct sc_gl_external_copy_fns *f = copy->fns;

    GLint saved_active = 0;
    f->GetIntegerv(GL_ACTIVE_TEXTURE, &saved_active);
    f->ActiveTexture(GL_TEXTURE0);
    GLint saved_external = 0;
    f->GetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &saved_external);

    while (gl->GetError()); // Clear any errors left
    GLuint texture;
    f->GenTextures(1, &texture);
    gl->BindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
    egl->EGLImageTargetTexture2DOES(GL_TEXTURE_EXTERNAL_OES, image);
    GLenum error = gl->GetError();
    // The copy is 1:1
    gl->TexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER,
                      GL_NEAREST);
    gl->TexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER,
                      GL_NEAREST);
    gl->BindTexture(GL_TEXTURE_EXTERNAL_OES, (GLuint) saved_external);
    f->ActiveTexture((GLenum) saved_active);
    while (gl->GetError());

    if (error) {
        LOGE("Could not attach the EGLImage to an external texture "
             "(GL error %#x)", error);
        f->DeleteTextures(1, &texture);
        return 0;
    }
    return texture;
}

void
sc_gl_external_copy_destroy_texture(struct sc_gl_external_copy *copy,
                                    unsigned texture) {
    assert(copy->initialized);
    GLuint t = texture;
    copy->fns->DeleteTextures(1, &t);
}

bool
sc_gl_external_copy_run(struct sc_gl_external_copy *copy, struct sc_opengl *gl,
                        unsigned external_texture, unsigned texture_2d,
                        int width, int height) {
    assert(copy->initialized);
    struct sc_gl_external_copy_fns *f = copy->fns;

    // Save everything the copy changes, so that the SDL renderer's cached
    // state stays true
    GLint saved_framebuffer = 0;
    GLint saved_program = 0;
    GLint saved_viewport[4] = {0};
    GLint saved_active = 0;
    GLint saved_external = 0;
    GLint saved_buffer = 0;
    GLint attrib_enabled = 0;
    GLint attrib_size = 4;
    GLint attrib_type = GL_FLOAT;
    GLint attrib_normalized = 0;
    GLint attrib_stride = 0;
    GLint attrib_buffer = 0;
    void *attrib_pointer = NULL;
    f->GetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_framebuffer);
    f->GetIntegerv(GL_CURRENT_PROGRAM, &saved_program);
    f->GetIntegerv(GL_VIEWPORT, saved_viewport);
    f->GetIntegerv(GL_ACTIVE_TEXTURE, &saved_active);
    f->GetIntegerv(GL_ARRAY_BUFFER_BINDING, &saved_buffer);
    f->GetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &attrib_enabled);
    f->GetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &attrib_size);
    f->GetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &attrib_type);
    f->GetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED,
                         &attrib_normalized);
    f->GetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &attrib_stride);
    f->GetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING,
                         &attrib_buffer);
    f->GetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER,
                               &attrib_pointer);
    bool blend = f->IsEnabled(GL_BLEND);
    bool scissor = f->IsEnabled(GL_SCISSOR_TEST);
    bool cull = f->IsEnabled(GL_CULL_FACE);
    bool depth = f->IsEnabled(GL_DEPTH_TEST);
    f->ActiveTexture(GL_TEXTURE0);
    f->GetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &saved_external);

    while (gl->GetError()); // Clear any errors left

    f->BindFramebuffer(GL_FRAMEBUFFER, copy->framebuffer);
    f->FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_TEXTURE_2D, texture_2d, 0);
    bool complete = f->CheckFramebufferStatus(GL_FRAMEBUFFER)
                 == GL_FRAMEBUFFER_COMPLETE;
    if (complete) {
        if (blend) {
            f->Disable(GL_BLEND);
        }
        if (scissor) {
            f->Disable(GL_SCISSOR_TEST);
        }
        if (cull) {
            f->Disable(GL_CULL_FACE);
        }
        if (depth) {
            f->Disable(GL_DEPTH_TEST);
        }
        f->Viewport(0, 0, width, height);
        f->UseProgram(copy->program);
        f->Uniform1i(copy->tex_location, 0);
        gl->BindTexture(GL_TEXTURE_EXTERNAL_OES, external_texture);
        f->BindBuffer(GL_ARRAY_BUFFER, copy->vertex_buffer);
        f->VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
        f->EnableVertexAttribArray(0);
        f->DrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
    GLenum error = gl->GetError();

    // Restore
    f->FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_TEXTURE_2D, 0, 0);
    f->BindFramebuffer(GL_FRAMEBUFFER, (GLuint) saved_framebuffer);
    f->BindBuffer(GL_ARRAY_BUFFER, (GLuint) attrib_buffer);
    f->VertexAttribPointer(0, attrib_size, (GLenum) attrib_type,
                           attrib_normalized ? GL_TRUE : GL_FALSE,
                           attrib_stride, attrib_pointer);
    f->BindBuffer(GL_ARRAY_BUFFER, (GLuint) saved_buffer);
    if (attrib_enabled) {
        f->EnableVertexAttribArray(0);
    } else {
        f->DisableVertexAttribArray(0);
    }
    gl->BindTexture(GL_TEXTURE_EXTERNAL_OES, (GLuint) saved_external);
    f->ActiveTexture((GLenum) saved_active);
    f->UseProgram((GLuint) saved_program);
    f->Viewport(saved_viewport[0], saved_viewport[1], saved_viewport[2],
                saved_viewport[3]);
    if (blend) {
        f->Enable(GL_BLEND);
    }
    if (scissor) {
        f->Enable(GL_SCISSOR_TEST);
    }
    if (cull) {
        f->Enable(GL_CULL_FACE);
    }
    if (depth) {
        f->Enable(GL_DEPTH_TEST);
    }
    while (gl->GetError());

    if (!complete) {
        LOGE("Could not render into the frame texture (incomplete "
             "framebuffer)");
        return false;
    }
    if (error) {
        LOGE("Could not copy the external texture (GL error %#x)", error);
        return false;
    }
    return true;
}
