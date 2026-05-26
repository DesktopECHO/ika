#ifndef SC_SCREEN_H
#define SC_SCREEN_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <SDL3/SDL.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>

#include "controller.h"
#include "coords.h"
#include "disconnect.h"
#include "fps_counter.h"
#include "frame_buffer.h"
#include "input_manager.h"
#include "mouse_capture.h"
#include "options.h"
#include "texture.h"
#include "trait/key_processor.h"
#include "trait/frame_sink.h"
#include "trait/mouse_processor.h"
#include "util/process.h"
#include "util/tick.h"

#ifdef __APPLE__
# define SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
#endif

#define SC_RAW_FRAME_BUFFER_POOL_SIZE 4

struct sc_raw_frame_buffer {
    uint8_t *pixels;
    size_t capacity;
};

struct sc_screen {
    struct sc_frame_sink frame_sink; // frame sink trait

#ifndef NDEBUG
    bool open; // track the open/close state to assert correct behavior
#endif

    bool video;
    bool camera;
    bool window_aspect_ratio_lock;
    bool flex_display;

    struct sc_controller *controller;

    struct sc_texture tex;
    struct sc_input_manager im;
    struct sc_mouse_capture mc; // only used in mouse relative mode
    struct sc_fps_counter fps_counter;

    struct sc_mutex mutex;
    struct sc_frame_buffer fb; // protected by mutex
    // When true, a frame size change must not cause the window to be resized
    bool prevent_auto_resize; // protected by mutex

    // The initial requested window properties
    struct {
        int16_t x;
        int16_t y;
        uint16_t width;
        uint16_t height;
        bool fullscreen;
        bool start_fps_counter;
    } req;

    SDL_Window *window;
    SDL_Renderer *renderer;
#ifdef SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
    SDL_GLContext gl_context;
#endif

    enum sc_render_fit render_fit;

    struct sc_size frame_size;
    struct sc_size content_size; // rotated frame_size
    // Last requested remote display size (in device orientation), used to
    // Deduplicate resize requests while dpi-driven resizing is active.
    struct sc_size last_requested_display_size;
    bool resize_display_using_pixel_size;
    const char *cuttlefish_frames_socket;
    uint32_t cuttlefish_display_id;
    uint16_t flex_display_dpi;
    uint16_t launch_display_dpi;    // flex_display_dpi at init, for DPI ratio
    float initial_display_scale;    // host display scale at init, for DPI ratio
    sc_pid cuttlefish_resize_pid;   // async resize child, reaped before next spawn
    sc_tick last_resize_request_tick;
    bool initial_window_show_deferred;
    struct sc_size initial_display_size;
    sc_tick initial_window_prepare_tick;
    SDL_TimerID initial_window_show_timer; // protected by mutex
    bool transient_stretch;
    struct sc_size transient_stretch_source_size;
    SDL_Texture *resize_preview_texture;
    struct sc_size resize_preview_size;
    sc_tick last_resize_event_tick;
    // Set once the device reports DISPLAY_READY for last_requested_display_size.
    // The stretched preview is released only after this is true, the host
    // window has been quiet for FLEX_DISPLAY_RESIZE_QUIET_DELAY, and a raw
    // frame newer than the current display resize request has arrived.
    bool display_ready;
    sc_tick display_ready_tick;
    bool display_ready_raw_frame;
    // Set when the resize hold begins, so the blur ghost overlay can ramp in
    // gradually during transient_stretch instead of snapping to full strength.
    sc_tick blur_fade_in_start_tick;
    // Set when the resize hold releases and the blur begins its fade-out.
    // transient_stretch is already false at this point; the texture has been
    // swapped to the new content, but the blur ghost overlay decays from
    // blur_fade_start_intensity to zero.
    sc_tick blur_fade_start_tick;
    float blur_fade_start_intensity;
    SDL_TimerID resize_settle_timer; // protected by mutex
    SDL_TimerID blur_fade_timer; // protected by mutex
    bool hotspot_button_down;
    bool hotspot_press_started_in_hotspot;
    bool hotspot_dragged;
    sc_tick hotspot_press_tick;
    bool hotspot_drag_pending;
    bool maximized_hotspot_press_pending;
    sc_tick maximized_hotspot_press_tick;
    float maximized_hotspot_press_x;
    float maximized_hotspot_press_y;

    bool resize_pending; // resize requested while fullscreen or maximized
    // The content size the last time the window was not maximized or
    // fullscreen (meaningful only when resize_pending is true)
    struct sc_size windowed_content_size;

    // client orientation
    enum sc_orientation orientation;
    // rectangle of the content (excluding black borders)
    struct SDL_FRect rect;
    bool window_shown;

    // only accessed from the thread calling sc_frame_sink_ops functions
    struct sc_stream_session current_session;

    AVFrame *frame;

    struct {
        uint32_t display_number;
        struct sc_size size;
        uint32_t fourcc;
        SDL_PixelFormat format;
        uint32_t stride;
        uint8_t *pixels;
        size_t size_bytes;
        int dmabuf_fd;
        uint32_t offset;
        uint32_t modifier_hi;
        uint32_t modifier_lo;
        sc_tick received_tick;
        bool is_dmabuf;
        bool owns_pixels;
    } pending_raw_frame, raw_frame;
    bool pending_raw_frame_available; // protected by mutex
    bool raw_frame_event_pending; // protected by mutex
    bool raw_frame_source_open;
    SDL_TimerID raw_frame_refresh_timer; // protected by mutex
    struct sc_raw_frame_buffer
        raw_frame_buffer_pool[SC_RAW_FRAME_BUFFER_POOL_SIZE];
    size_t raw_frame_buffer_next;
    sc_tick last_raw_frame_render_tick; // protected by mutex
    sc_tick last_raw_frame_resize_tick; // protected by mutex

    bool paused;
    AVFrame *resume_frame;

    bool disconnected;
    bool disconnect_started;
    struct sc_disconnect disconnect;
};

struct sc_screen_params {
    bool video;
    bool camera;
    bool flex_display;
    bool resize_display_using_pixel_size;
    const char *cuttlefish_frames_socket;
    uint32_t cuttlefish_display_id;
    uint16_t flex_display_dpi;

    struct sc_controller *controller;
    struct sc_file_pusher *fp;
    struct sc_key_processor *kp;
    struct sc_mouse_processor *mp;
    struct sc_gamepad_processor *gp;

    struct sc_mouse_bindings mouse_bindings;
    bool legacy_paste;
    bool clipboard_autosync;
    uint8_t shortcut_mods; // OR of enum sc_shortcut_mod values

    const char *window_title;
    bool always_on_top;

    int16_t window_x; // accepts SC_WINDOW_POSITION_UNDEFINED
    int16_t window_y; // accepts SC_WINDOW_POSITION_UNDEFINED
    uint16_t window_width;
    uint16_t window_height;

    bool window_aspect_ratio_lock;
    bool window_borderless;

    enum sc_render_fit render_fit;
    enum sc_orientation orientation;
    bool mipmaps;

    bool fullscreen;
    bool start_fps_counter;
};

// initialize screen, create window, renderer and texture (window is hidden)
bool
sc_screen_init(struct sc_screen *screen, const struct sc_screen_params *params);

// request to interrupt any inner thread
// must be called before sc_screen_join()
void
sc_screen_interrupt(struct sc_screen *screen);

// join any inner thread
void
sc_screen_join(struct sc_screen *screen);

// destroy window, renderer and texture (if any)
void
sc_screen_destroy(struct sc_screen *screen);

// hide the window
//
// It is used to hide the window immediately on closing without waiting for
// screen_destroy()
void
sc_screen_hide_window(struct sc_screen *screen);

// toggle the fullscreen mode
void
sc_screen_toggle_fullscreen(struct sc_screen *screen);

// toggle window decorations
void
sc_screen_toggle_window_bordered(struct sc_screen *screen);

// resize window to optimal size (remove black borders)
void
sc_screen_resize_to_fit(struct sc_screen *screen);

// resize window to 1:1 (pixel-perfect)
void
sc_screen_resize_to_pixel_perfect(struct sc_screen *screen);

// set the display orientation
void
sc_screen_set_orientation(struct sc_screen *screen,
                          enum sc_orientation orientation);

// set the display pause state
void
sc_screen_set_paused(struct sc_screen *screen, bool paused);

// Push one raw video frame from an external producer.
bool
sc_screen_push_raw_frame(struct sc_screen *screen, uint32_t display_number,
                         uint32_t width, uint32_t height, uint32_t fourcc,
                         SDL_PixelFormat format, uint32_t stride,
                         uint8_t *pixels, size_t size_bytes,
                         bool owns_pixels);

uint8_t *
sc_screen_alloc_raw_frame_buffer(struct sc_screen *screen, size_t size);

void
sc_screen_recycle_raw_frame_buffer(struct sc_screen *screen, uint8_t *pixels,
                                   size_t capacity);

bool
sc_screen_push_dmabuf_frame(struct sc_screen *screen, uint32_t display_number,
                            uint32_t width, uint32_t height, uint32_t fourcc,
                            SDL_PixelFormat format, int dmabuf_fd,
                            uint32_t offset, uint32_t stride,
                            uint32_t modifier_hi, uint32_t modifier_lo);

void
sc_screen_close_raw_frame_source(struct sc_screen *screen);

// react to SDL events
void
sc_screen_handle_event(struct sc_screen *screen, const SDL_Event *event);

// run the event loop once the device is disconnected
void
sc_screen_handle_disconnection(struct sc_screen *screen);

// convert point from window coordinates to frame coordinates
// x and y are expressed in pixels
struct sc_point
sc_screen_convert_window_to_frame_coords(struct sc_screen *screen,
                                        int32_t x, int32_t y);

// convert point from drawable coordinates to frame coordinates
// x and y are expressed in pixels
struct sc_point
sc_screen_convert_drawable_to_frame_coords(struct sc_screen *screen,
                                          int32_t x, int32_t y);

struct sc_size
sc_screen_get_input_size(struct sc_screen *screen);

struct sc_point
sc_screen_convert_window_to_input_coords(struct sc_screen *screen,
                                        int32_t x, int32_t y);

struct sc_point
sc_screen_convert_drawable_to_input_coords(struct sc_screen *screen,
                                          int32_t x, int32_t y);

// Convert coordinates from window to drawable.
// Events are expressed in window coordinates, but content is expressed in
// drawable coordinates. They are the same if HiDPI scaling is 1, but differ
// otherwise.
void
sc_screen_hidpi_scale_coords(struct sc_screen *screen, int32_t *x, int32_t *y);

// Handler for DEVICE_MSG_TYPE_DISPLAY_READY. Called on the main thread after
// the receiver forwards the device-side signal that the guest has finished a
// resize. transient_stretch only clears once this signal has arrived and the
// host window has not resized for the settle delay and a raw frame newer than
// the current display resize request has arrived. display_id, width, height are
// reported by the device for the client to sanity-check against its last
// request.
void
sc_screen_on_display_ready(struct sc_screen *screen, uint32_t display_id,
                           uint16_t width, uint16_t height);

#endif
