#ifndef SC_IKA_GAMEPAD_FOCUS_H
#define SC_IKA_GAMEPAD_FOCUS_H

#include "common.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "trait/gamepad_processor.h"

// The most gamepads (the keyboard gamepad and real ones) passed to the device
// at once; more are ignored
#define SC_GAMEPAD_FOCUS_MAX_GAMEPADS 8

/**
 * Passes the host's gamepads (the keyboard gamepad and real ones) to the
 * device, each as a gamepad of its own, only while the window has the focus:
 * a game in the background has no gamepad, and of Ika's windows (the console
 * and each app window, every one with its own) only the focused one gives the
 * device gamepads.
 *
 * It is the gamepad processor the gamepads send their events to, and passes
 * them on to the device's processor (the UHID gamepad): each gamepad is added
 * to the device when the window gains the focus, or when it is connected
 * while the window has it, and removed when the window loses the focus.
 */
struct sc_gamepad_focus {
    struct sc_gamepad_processor gamepad_processor; // gamepad processor trait

    struct sc_gamepad_processor *out;
    struct {
        uint32_t id;
        const char *name; // NULL: the device's processor asks SDL
    } gamepads[SC_GAMEPAD_FOCUS_MAX_GAMEPADS];
    size_t count;
    bool focused;
};

// With follow_focus false (no window), the gamepads are passed to the device
// whenever they are connected
void
sc_gamepad_focus_init(struct sc_gamepad_focus *gf,
                      struct sc_gamepad_processor *out, bool follow_focus);

// The window gained or lost the focus
void
sc_gamepad_focus_set_focused(struct sc_gamepad_focus *gf, bool focused);

#endif
