#include "keyboard_gamepad_timer.h"

#include <SDL3/SDL_timer.h>

#include "events.h"
#include "util/log.h"

// A ramp takes a few ticks; the ticks are HID reports, 8 ms is a gamepad's
// usual report rate
#define SC_KEYBOARD_GAMEPAD_TICK_MS 8

static SDL_TimerID timer;

static uint32_t
sc_keyboard_gamepad_timer_cb(void *userdata, SDL_TimerID id,
                             uint32_t interval) {
    (void) userdata;
    (void) id;
    bool ok = sc_push_event(SC_EVENT_GAMEKB_TIMER);
    (void) ok; // ignore failure, the next tick tries again
    return interval;
}

static void
sc_keyboard_gamepad_timer_arm(void *userdata) {
    (void) userdata;
    if (timer) {
        return;
    }
    timer = SDL_AddTimer(SC_KEYBOARD_GAMEPAD_TICK_MS,
                         sc_keyboard_gamepad_timer_cb, NULL);
    if (!timer) {
        LOGW("Could not start the keyboard gamepad's ramp timer: %s",
             SDL_GetError());
    }
}

static void
sc_keyboard_gamepad_timer_stop(void) {
    if (timer) {
        SDL_RemoveTimer(timer);
        timer = 0;
    }
}

const struct sc_keyboard_gamepad_timer SC_KEYBOARD_GAMEPAD_SDL_TIMER = {
    .arm = sc_keyboard_gamepad_timer_arm,
    .userdata = NULL,
};

void
sc_keyboard_gamepad_timer_on_event(struct sc_keyboard_gamepad *kg) {
    if (!sc_keyboard_gamepad_tick(kg, SDL_GetTicks())) {
        sc_keyboard_gamepad_timer_stop();
    }
}

void
sc_keyboard_gamepad_timer_destroy(void) {
    sc_keyboard_gamepad_timer_stop();
}
