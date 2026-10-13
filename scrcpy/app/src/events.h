#ifndef SC_EVENTS_H
#define SC_EVENTS_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_init.h>

enum {
    SC_EVENT_NEW_FRAME = SDL_EVENT_USER,
    SC_EVENT_OPEN_WINDOW,
    SC_EVENT_DEVICE_DISCONNECTED,
    SC_EVENT_SERVER_CONNECTION_FAILED,
    SC_EVENT_SERVER_CONNECTED,
    SC_EVENT_DEMUXER_ERROR,
    SC_EVENT_DECODER_ERROR,
    SC_EVENT_RECORDER_ERROR,
    SC_EVENT_TIME_LIMIT_REACHED,
    SC_EVENT_CONTROLLER_ERROR,
    SC_EVENT_AOA_OPEN_ERROR,
    SC_EVENT_DISCONNECTED_ICON_LOADED,
    SC_EVENT_DISCONNECTED_TIMEOUT,
    // The device display reached the size requested by the client (data1
    // holds the size, see SC_EVENT_SIZE_PACK())
    SC_EVENT_DISPLAY_READY,
    // The app of the new virtual display is gone
    SC_EVENT_APP_ENDED,
    // The window left fullscreen in an Ika game session
    SC_EVENT_GAME_SESSION_ENDED,
    // A flex display resize timer expired
    SC_EVENT_FLEX_TIMER,
};

// Pack a 16-bit size into an event pointer, to avoid an allocation
#define SC_EVENT_SIZE_PACK(W, H) \
    ((void *) (uintptr_t) (((uint32_t) (W) << 16) | (uint16_t) (H)))
#define SC_EVENT_SIZE_WIDTH(PTR) ((uint16_t) ((uintptr_t) (PTR) >> 16))
#define SC_EVENT_SIZE_HEIGHT(PTR) ((uint16_t) (uintptr_t) (PTR))

bool
sc_push_event_impl(uint32_t type, void *ptr, const char *name);

#define sc_push_event(TYPE) sc_push_event_impl(TYPE, NULL, # TYPE)
#define sc_push_event_with_data(TYPE, PTR) sc_push_event_impl(TYPE, PTR, # TYPE)

bool sc_dequeue_event(uint32_t type, SDL_Event *event);

typedef SDL_MainThreadCallback sc_runnable_fn;

bool
sc_main_thread_init(void);

void
sc_main_thread_destroy(void);

bool
sc_run_on_main_thread(sc_runnable_fn run, void *userdata, bool wait_complete);

// Reject new runnables after this call
void
sc_main_thread_stop(void);

#endif
