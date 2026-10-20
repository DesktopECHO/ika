#ifndef SC_IKA_KEYBOARD_GAMEPAD_H
#define SC_IKA_KEYBOARD_GAMEPAD_H

#include "common.h"

#include <stdbool.h>
#include <stddef.h>
#include <SDL3/SDL.h>

#include "trait/gamepad_processor.h"

// The keyboard gamepad's id, outside the range of SDL joystick ids
#define SC_KEYBOARD_GAMEPAD_ID 0xFFFFFFFFu

#define SC_KEYBOARD_GAMEPAD_MAX_KEYS 64

/**
 * The keyboard as a gamepad (--gamekb[=SPEC]).
 *
 * Mapped keys drive a gamepad of the device, through the gamepad processor,
 * instead of typing; other keys still reach the keyboard processor. SPEC
 * lists the keys of each control, as "control=key/key,control=key": the
 * controls are dpad_up, dpad_down, dpad_left, dpad_right (which also move the
 * left stick), a, b, x, y, start, back, guide, left_shoulder, right_shoulder,
 * left_stick, right_stick, left_trigger and right_trigger; the keys are SDL
 * key names, with "_" for a space (Keypad_Enter). Without SPEC: arrows or
 * WASD steer, Space is A, Esc is B, C is X, V is Y, Enter is Start, Backspace
 * is Back, Q and E are the shoulders, Z and X the triggers.
 */

enum sc_keyboard_gamepad_kind {
    SC_KEYBOARD_GAMEPAD_KIND_UP,
    SC_KEYBOARD_GAMEPAD_KIND_DOWN,
    SC_KEYBOARD_GAMEPAD_KIND_LEFT,
    SC_KEYBOARD_GAMEPAD_KIND_RIGHT,
    SC_KEYBOARD_GAMEPAD_KIND_BUTTON,
    SC_KEYBOARD_GAMEPAD_KIND_LEFT_TRIGGER,
    SC_KEYBOARD_GAMEPAD_KIND_RIGHT_TRIGGER,
};

struct sc_keyboard_gamepad_key {
    SDL_Scancode scancode;
    enum sc_keyboard_gamepad_kind kind;
    enum sc_gamepad_button button; // for SC_KEYBOARD_GAMEPAD_KIND_BUTTON
    bool held; // pressed on the gamepad, until its release
};

struct sc_keyboard_gamepad {
    struct sc_gamepad_processor *gp;
    struct sc_keyboard_gamepad_key keys[SC_KEYBOARD_GAMEPAD_MAX_KEYS];
    size_t key_count;
    // Held direction keys: releasing one restores another still held
    bool up;
    bool down;
    bool left;
    bool right;
};

// spec: the keys of each control, or NULL or "" for the default keys. Keys and
// controls that are not understood are reported and skipped.
void
sc_keyboard_gamepad_init(struct sc_keyboard_gamepad *kg,
                         struct sc_gamepad_processor *gp, const char *spec);

// Announces the keyboard gamepad to the device
void
sc_keyboard_gamepad_plug(struct sc_keyboard_gamepad *kg);

// Returns true if the key event was a gamepad key, now handled. A press with
// Ctrl, Alt or Super is not one (it types). The release of a held key always
// is, whatever modifier is down by then, so call it for every key release
// before any other handling: a modifier pressed while a gamepad key is held,
// or the keys SDL releases on focus loss with the modifiers still down, would
// otherwise leave the button pressed on the device.
bool
sc_keyboard_gamepad_handle_key(struct sc_keyboard_gamepad *kg,
                               const SDL_KeyboardEvent *event);

// Releases every held key, for when the window loses focus
void
sc_keyboard_gamepad_release_all(struct sc_keyboard_gamepad *kg);

#endif
