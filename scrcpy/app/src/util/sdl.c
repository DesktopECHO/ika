#include "sdl.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>
#ifdef __linux__
# include <dlfcn.h>
#endif

#include "util/log.h"

SDL_Window *
sc_sdl_create_window(const char *title, int64_t x, int64_t y, int64_t width,
                     int64_t height, int64_t flags) {
    SDL_Window *window = NULL;

    SDL_PropertiesID props = SDL_CreateProperties();
    if (!props) {
        return NULL;
    }

    bool ok =
        SDL_SetStringProperty(props, SDL_PROP_WINDOW_CREATE_TITLE_STRING,
                              title);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_X_NUMBER, x);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_Y_NUMBER, y);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER,
                                width);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER,
                                height);
    ok &= SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER,
                                flags);

    if (!ok) {
        SDL_DestroyProperties(props);
        return NULL;
    }

    window = SDL_CreateWindowWithProperties(props);
    SDL_DestroyProperties(props);
    return window;
}

struct sc_size
sc_sdl_get_window_size(SDL_Window *window) {
    int width;
    int height;
    bool ok = SDL_GetWindowSize(window, &width, &height);
    if (!ok) {
        LOGE("Could not get window size: %s", SDL_GetError());
        LOGE("Please report the error");
        // fatal error
        abort();
    }

    struct sc_size size = {
        .width = width,
        .height = height,
    };
    return size;
}

struct sc_size
sc_sdl_get_window_size_in_pixels(SDL_Window *window) {
    int width;
    int height;
    bool ok = SDL_GetWindowSizeInPixels(window, &width, &height);
    if (!ok) {
        LOGE("Could not get window size: %s", SDL_GetError());
        LOGE("Please report the error");
        // fatal error
        abort();
    }

    struct sc_size size = {
        .width = width,
        .height = height,
    };
    return size;
}

void
sc_sdl_set_window_size(SDL_Window *window, struct sc_size size) {
    bool ok = SDL_SetWindowSize(window, size.width, size.height);
    if (!ok) {
        LOGE("Could not set window size: %s", SDL_GetError());
        assert(!"unexpected");
    }
}

struct sc_point
sc_sdl_get_window_position(SDL_Window *window) {
    int x;
    int y;
    bool ok = SDL_GetWindowPosition(window, &x, &y);
    if (!ok) {
        LOGE("Could not get window position: %s", SDL_GetError());
        LOGE("Please report the error");
        // fatal error
        abort();
    }

    struct sc_point point = {
        .x = x,
        .y = y,
    };
    return point;
}

void
sc_sdl_set_window_position(SDL_Window *window, struct sc_point point) {
    bool ok = SDL_SetWindowPosition(window, point.x, point.y);
    if (!ok) {
        const char *error = SDL_GetError();
        if (error
                && strstr(error,
                          "wayland cannot position non-popup windows")) {
            return;
        }

        LOGW("Could not set window position: %s", error);
    }
}

void
sc_sdl_show_window(SDL_Window *window) {
    bool ok = SDL_ShowWindow(window);
    if (!ok) {
        LOGE("Could not show window: %s", SDL_GetError());
        assert(!"unexpected");
    }
}

void
sc_sdl_hide_window(SDL_Window *window) {
    bool ok = SDL_HideWindow(window);
    if (!ok) {
        LOGE("Could not hide window: %s", SDL_GetError());
        assert(!"unexpected");
    }
}

struct sc_size
sc_sdl_get_render_output_size(SDL_Renderer *renderer) {
    int width;
    int height;
    bool ok = SDL_GetRenderOutputSize(renderer, &width, &height);
    if (!ok) {
        LOGE("Could not get render output size: %s", SDL_GetError());
        LOGE("Please report the error");
        // fatal error
        abort();
    }

    struct sc_size size = {
        .width = width,
        .height = height,
    };
    return size;
}

bool
sc_sdl_render_clear(SDL_Renderer *renderer) {
    bool ok = SDL_RenderClear(renderer);
    if (!ok) {
        LOGW("Could not clear rendering: %s", SDL_GetError());
    }
    return ok;
}

void
sc_sdl_render_present(SDL_Renderer *renderer) {
    bool ok = SDL_RenderPresent(renderer);
    if (!ok) {
        LOGE("Could not render: %s", SDL_GetError());
        assert(!"unexpected");
    }
}

#ifdef __linux__
void
sc_sdl_apply_gtk_theme_variant(SDL_Window *window) {
    // On X11 the window manager draws the title bar; GNOME's picks the dark
    // variant from the window's _GTK_THEME_VARIANT property. Take the variant
    // from GTK_THEME (e.g. "Adwaita:dark"), which on Wayland already reaches
    // the title bar through libdecor's GTK plugin.
    const char *driver = SDL_GetCurrentVideoDriver();
    if (!driver || strcmp(driver, "x11")) {
        return;
    }
    const char *theme = getenv("GTK_THEME");
    const char *variant = theme ? strrchr(theme, ':') : NULL;
    if (!variant || strcmp(variant + 1, "dark")) {
        return;
    }

    SDL_PropertiesID props = SDL_GetWindowProperties(window);
    void *display = SDL_GetPointerProperty(props,
                                    SDL_PROP_WINDOW_X11_DISPLAY_POINTER, NULL);
    Sint64 xwindow = SDL_GetNumberProperty(props,
                                    SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    if (!display || !xwindow) {
        return;
    }

    // Resolve Xlib from the libX11 SDL already loaded, so scrcpy does not
    // link against it.
    void *x11 = dlopen("libX11.so.6", RTLD_LAZY | RTLD_NOLOAD);
    if (!x11) {
        return;
    }
    unsigned long (*intern_atom)(void *, const char *, int) =
        (unsigned long (*)(void *, const char *, int))
            dlsym(x11, "XInternAtom");
    int (*change_property)(void *, unsigned long, unsigned long,
                           unsigned long, int, int, const unsigned char *,
                           int) =
        (int (*)(void *, unsigned long, unsigned long, unsigned long, int, int,
                 const unsigned char *, int))
            dlsym(x11, "XChangeProperty");
    int (*flush)(void *) = (int (*)(void *)) dlsym(x11, "XFlush");
    if (intern_atom && change_property && flush) {
        static const char dark[] = "dark";
        unsigned long property = intern_atom(display, "_GTK_THEME_VARIANT", 0);
        unsigned long utf8_string = intern_atom(display, "UTF8_STRING", 0);
        // 8-bit format, PropModeReplace (0)
        change_property(display, (unsigned long) xwindow, property,
                        utf8_string, 8, 0, (const unsigned char *) dark,
                        (int) strlen(dark));
        flush(display);
    }
    dlclose(x11);
}
#else
void
sc_sdl_apply_gtk_theme_variant(SDL_Window *window) {
    (void) window;
}
#endif
