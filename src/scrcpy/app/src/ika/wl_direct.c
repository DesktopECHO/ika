#include "wl_direct.h"

#include <assert.h>
#include <dlfcn.h>
#include <string.h>

#include "ika/cf_source.h"
#include "util/log.h"

// libwayland-client is loaded by SDL: its calls are looked up, so that scrcpy
// does not link it. The requests are marshalled by opcode.
#define SC_WL_MARSHAL_FLAG_DESTROY (1 << 0)
#define SC_WL_DISPLAY_GET_REGISTRY 1
#define SC_WL_REGISTRY_BIND 0
#define SC_WL_SHM_CREATE_POOL 0
#define SC_WL_SHM_POOL_CREATE_BUFFER 0
#define SC_WL_SHM_POOL_DESTROY 1
#define SC_WL_BUFFER_DESTROY 0
#define SC_WL_SURFACE_ATTACH 1
#define SC_WL_SURFACE_DAMAGE 2
#define SC_WL_SURFACE_COMMIT 6
#define SC_WL_SURFACE_DAMAGE_BUFFER 9 // since version 4
#define SC_WL_SHM_FORMAT_XRGB8888 1

typedef void *(*sc_wl_marshal_flags_fn)(void *proxy, uint32_t opcode,
                                        const void *interface,
                                        uint32_t version, uint32_t flags, ...);
typedef uint32_t (*sc_wl_get_version_fn)(void *proxy);
typedef int (*sc_wl_add_listener_fn)(void *proxy, void (**impl)(void),
                                     void *data);
typedef void *(*sc_wl_create_wrapper_fn)(void *proxy);
typedef void (*sc_wl_wrapper_destroy_fn)(void *wrapper);
typedef void (*sc_wl_set_queue_fn)(void *proxy, void *queue);
typedef void (*sc_wl_proxy_destroy_fn)(void *proxy);
typedef void *(*sc_wl_create_queue_fn)(void *display);
typedef void (*sc_wl_queue_destroy_fn)(void *queue);
typedef int (*sc_wl_queue_fn)(void *display, void *queue);
typedef int (*sc_wl_flush_fn)(void *display);

static struct {
    sc_wl_marshal_flags_fn marshal_flags;
    sc_wl_get_version_fn get_version;
    sc_wl_add_listener_fn add_listener;
    sc_wl_create_wrapper_fn create_wrapper;
    sc_wl_wrapper_destroy_fn wrapper_destroy;
    sc_wl_set_queue_fn set_queue;
    sc_wl_proxy_destroy_fn proxy_destroy;
    sc_wl_create_queue_fn create_queue;
    sc_wl_queue_destroy_fn queue_destroy;
    sc_wl_queue_fn roundtrip_queue;
    sc_wl_queue_fn dispatch_queue_pending;
    sc_wl_flush_fn flush;
    const void *registry_interface;
    const void *shm_interface;
    const void *shm_pool_interface;
    const void *buffer_interface;
} wl;

static bool
sc_wl_direct_load(void *lib) {
#define SC_WL_SYM(field, name) \
    *(void **) &wl.field = dlsym(lib, name); \
    if (!wl.field) { \
        LOGD("Direct presentation: no %s", name); \
        return false; \
    }
    SC_WL_SYM(marshal_flags, "wl_proxy_marshal_flags");
    SC_WL_SYM(get_version, "wl_proxy_get_version");
    SC_WL_SYM(add_listener, "wl_proxy_add_listener");
    SC_WL_SYM(create_wrapper, "wl_proxy_create_wrapper");
    SC_WL_SYM(wrapper_destroy, "wl_proxy_wrapper_destroy");
    SC_WL_SYM(set_queue, "wl_proxy_set_queue");
    SC_WL_SYM(proxy_destroy, "wl_proxy_destroy");
    SC_WL_SYM(create_queue, "wl_display_create_queue");
    SC_WL_SYM(queue_destroy, "wl_event_queue_destroy");
    SC_WL_SYM(roundtrip_queue, "wl_display_roundtrip_queue");
    SC_WL_SYM(dispatch_queue_pending, "wl_display_dispatch_queue_pending");
    SC_WL_SYM(flush, "wl_display_flush");
    SC_WL_SYM(registry_interface, "wl_registry_interface");
    SC_WL_SYM(shm_interface, "wl_shm_interface");
    SC_WL_SYM(shm_pool_interface, "wl_shm_pool_interface");
    SC_WL_SYM(buffer_interface, "wl_buffer_interface");
#undef SC_WL_SYM
    return true;
}

static void
sc_wl_direct_registry_global(void *data, void *registry, uint32_t name,
                             const char *interface, uint32_t version) {
    (void) version;
    struct sc_wl_direct *wd = data;
    if (!wd->shm && !strcmp(interface, "wl_shm")) {
        wd->shm = wl.marshal_flags(registry, SC_WL_REGISTRY_BIND,
                                   wl.shm_interface, 1, 0, name, "wl_shm", 1,
                                   NULL);
    }
}

static void
sc_wl_direct_registry_global_remove(void *data, void *registry,
                                    uint32_t name) {
    (void) data;
    (void) registry;
    (void) name;
}

static void (*const sc_wl_direct_registry_listener[])(void) = {
    (void (*)(void)) sc_wl_direct_registry_global,
    (void (*)(void)) sc_wl_direct_registry_global_remove,
};

static void
sc_wl_direct_free_entry(struct sc_wl_direct_buffer *entry) {
    wl.marshal_flags(entry->buffer, SC_WL_BUFFER_DESTROY, NULL,
                     wl.get_version(entry->buffer), SC_WL_MARSHAL_FLAG_DESTROY);
    entry->buffer = NULL;
    // The slot goes back to the server
    av_frame_free(&entry->frame);
}

static void
sc_wl_direct_buffer_release(void *data, void *buffer) {
    (void) buffer;
    sc_wl_direct_free_entry(data);
}

static void (*const sc_wl_direct_buffer_listener[])(void) = {
    (void (*)(void)) sc_wl_direct_buffer_release,
};

bool
sc_wl_direct_init(struct sc_wl_direct *wd, SDL_Window *window) {
    memset(wd, 0, sizeof(*wd));

    const char *driver = SDL_GetCurrentVideoDriver();
    if (!driver || strcmp(driver, "wayland")) {
        return false;
    }

    SDL_PropertiesID props = SDL_GetWindowProperties(window);
    wd->display = SDL_GetPointerProperty(props,
            SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    wd->surface = SDL_GetPointerProperty(props,
            SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    wd->wayland = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_NOLOAD);
    if (!wd->display || !wd->surface || !wd->wayland
            || !sc_wl_direct_load(wd->wayland)) {
        goto fail;
    }
    wd->surface_version = wl.get_version(wd->surface);

    // The objects are on a queue of their own, dispatched by scrcpy, not by
    // SDL's event loop
    wd->queue = wl.create_queue(wd->display);
    if (!wd->queue) {
        goto fail;
    }
    void *display = wl.create_wrapper(wd->display);
    if (!display) {
        goto fail;
    }
    wl.set_queue(display, wd->queue);
    void *registry = wl.marshal_flags(display, SC_WL_DISPLAY_GET_REGISTRY,
                                      wl.registry_interface,
                                      wl.get_version(display), 0, NULL);
    wl.wrapper_destroy(display);
    if (!registry) {
        goto fail;
    }
    wl.add_listener(registry, (void (**)(void)) sc_wl_direct_registry_listener,
                    wd);
    wl.roundtrip_queue(wd->display, wd->queue);
    wl.proxy_destroy(registry);
    if (!wd->shm) {
        LOGW("Direct presentation: no wl_shm");
        goto fail;
    }

    wd->enabled = true;
    return true;

fail:
    sc_wl_direct_destroy(wd);
    return false;
}

static void
sc_wl_direct_destroy_pool(struct sc_wl_direct *wd) {
    if (wd->pool) {
        // The buffers created from it keep their memory
        wl.marshal_flags(wd->pool, SC_WL_SHM_POOL_DESTROY, NULL,
                         wl.get_version(wd->pool), SC_WL_MARSHAL_FLAG_DESTROY);
        wd->pool = NULL;
    }
    av_buffer_unref(&wd->pool_slots);
}

void
sc_wl_direct_destroy(struct sc_wl_direct *wd) {
    if (wd->enabled) {
        for (size_t i = 0; i < ARRAY_LEN(wd->buffers); ++i) {
            if (wd->buffers[i].buffer) {
                sc_wl_direct_free_entry(&wd->buffers[i]);
            }
        }
        sc_wl_direct_destroy_pool(wd);
        wl.proxy_destroy(wd->shm);
        wl.flush(wd->display);
    }
    if (wd->queue) {
        wl.queue_destroy(wd->queue);
    }
    memset(wd, 0, sizeof(*wd));
}

void
sc_wl_direct_dispatch(struct sc_wl_direct *wd) {
    if (wd->enabled) {
        wl.dispatch_queue_pending(wd->display, wd->queue);
    }
}

static struct sc_wl_direct_buffer *
sc_wl_direct_get_free_entry(struct sc_wl_direct *wd) {
    for (size_t i = 0; i < ARRAY_LEN(wd->buffers); ++i) {
        if (!wd->buffers[i].buffer) {
            return &wd->buffers[i];
        }
    }
    return NULL;
}

bool
sc_wl_direct_can_present(struct sc_wl_direct *wd, const AVFrame *frame) {
    if (!wd->enabled || (frame->format != AV_PIX_FMT_BGR0
                         && frame->format != AV_PIX_FMT_BGRA)) {
        return false;
    }
    struct sc_cf_frame_slot slot;
    if (!sc_cf_frame_get_slot(frame, &slot)) {
        return false;
    }
    sc_wl_direct_dispatch(wd);
    return sc_wl_direct_get_free_entry(wd) != NULL;
}

bool
sc_wl_direct_present(struct sc_wl_direct *wd, const AVFrame *frame) {
    struct sc_cf_frame_slot slot;
    if (!sc_wl_direct_can_present(wd, frame)
            || !sc_cf_frame_get_slot(frame, &slot)) {
        return false;
    }

    if (!wd->pool_slots || wd->pool_slots->data != slot.slots->data) {
        // New slots (the server made them again)
        sc_wl_direct_destroy_pool(wd);
        wd->pool_slots = av_buffer_ref(slot.slots);
        if (!wd->pool_slots) {
            LOG_OOM();
            return false;
        }
        wd->pool = wl.marshal_flags(wd->shm, SC_WL_SHM_CREATE_POOL,
                                    wl.shm_pool_interface,
                                    wl.get_version(wd->shm), 0, NULL,
                                    slot.memfd, (int32_t) slot.size);
        if (!wd->pool) {
            av_buffer_unref(&wd->pool_slots);
            return false;
        }
    }

    struct sc_wl_direct_buffer *entry = sc_wl_direct_get_free_entry(wd);
    assert(entry);
    entry->frame = av_frame_alloc();
    if (!entry->frame || av_frame_ref(entry->frame, frame)) {
        LOG_OOM();
        av_frame_free(&entry->frame);
        return false;
    }

    // Opaque: the alpha channel of ARGB frames is undefined
    entry->buffer = wl.marshal_flags(wd->pool, SC_WL_SHM_POOL_CREATE_BUFFER,
                                     wl.buffer_interface,
                                     wl.get_version(wd->pool), 0, NULL,
                                     (int32_t) slot.offset,
                                     (int32_t) frame->width,
                                     (int32_t) frame->height,
                                     (int32_t) frame->linesize[0],
                                     (uint32_t) SC_WL_SHM_FORMAT_XRGB8888);
    if (!entry->buffer) {
        av_frame_free(&entry->frame);
        return false;
    }
    entry->owner = wd;
    wl.add_listener(entry->buffer,
                    (void (**)(void)) sc_wl_direct_buffer_listener, entry);

    void *surface = wd->surface;
    uint32_t version = wd->surface_version;
    wl.marshal_flags(surface, SC_WL_SURFACE_ATTACH, NULL, version, 0,
                     entry->buffer, (int32_t) 0, (int32_t) 0);
    if (version >= 4) {
        wl.marshal_flags(surface, SC_WL_SURFACE_DAMAGE_BUFFER, NULL, version,
                         0, (int32_t) 0, (int32_t) 0, (int32_t) frame->width,
                         (int32_t) frame->height);
    } else {
        wl.marshal_flags(surface, SC_WL_SURFACE_DAMAGE, NULL, version, 0,
                         (int32_t) 0, (int32_t) 0, (int32_t) INT32_MAX,
                         (int32_t) INT32_MAX);
    }
    wl.marshal_flags(surface, SC_WL_SURFACE_COMMIT, NULL, version, 0);
    wl.flush(wd->display);
    return true;
}
