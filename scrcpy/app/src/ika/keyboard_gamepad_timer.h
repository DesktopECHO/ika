#ifndef SC_IKA_KEYBOARD_GAMEPAD_TIMER_H
#define SC_IKA_KEYBOARD_GAMEPAD_TIMER_H

#include "common.h"

#include "keyboard_gamepad.h"

/**
 * The SDL timer behind the keyboard gamepad's stick ramps.
 *
 * Armed by the keyboard gamepad when a stick starts ramping, it pushes
 * SC_EVENT_GAMEKB_TIMER every few milliseconds; the main thread answers each
 * with sc_keyboard_gamepad_timer_on_event(), which ticks the gamepad and stops
 * the timer once no stick ramps any more.
 */

extern const struct sc_keyboard_gamepad_timer SC_KEYBOARD_GAMEPAD_SDL_TIMER;

// On SC_EVENT_GAMEKB_TIMER, from the main thread
void
sc_keyboard_gamepad_timer_on_event(struct sc_keyboard_gamepad *kg);

void
sc_keyboard_gamepad_timer_destroy(void);

#endif
