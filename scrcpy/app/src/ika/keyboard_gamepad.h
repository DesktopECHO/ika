#ifndef SC_IKA_KEYBOARD_GAMEPAD_H
#define SC_IKA_KEYBOARD_GAMEPAD_H

#include "common.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <SDL3/SDL.h>

#include "trait/gamepad_processor.h"

// The keyboard gamepad's id, outside the range of SDL joystick ids
#define SC_KEYBOARD_GAMEPAD_ID 0xFFFFFFFFu

#define SC_KEYBOARD_GAMEPAD_MAX_KEYS 64

// The D-pad and the two sticks, each steered by four direction keys
#define SC_KEYBOARD_GAMEPAD_PAD_COUNT 3

// The longest ramp a spec may ask for
#define SC_KEYBOARD_GAMEPAD_MAX_RAMP_MS 5000

/**
 * The keyboard as a gamepad (--gamekb[=SPEC]).
 *
 * Mapped keys drive a gamepad of the device, through the gamepad processor,
 * instead of typing; other keys still reach the keyboard processor. SPEC
 * lists the keys of each control, as "control=key/key,control=key": the
 * controls are left_stick_up, left_stick_down, left_stick_left,
 * left_stick_right, dpad_up, dpad_down, dpad_left, dpad_right,
 * right_stick_up, right_stick_down, right_stick_left, right_stick_right, a,
 * b, x, y, start, back, guide, left_shoulder, right_shoulder, left_stick,
 * right_stick (the sticks' clicks), left_trigger, right_trigger and walk (a
 * modifier: held, it caps the sticks' deflection); the keys are SDL key
 * names, with "_" for a space (Keypad_Enter), or the mouse's buttons and
 * wheel: Mouse_Left, Mouse_Right, Mouse_Middle, Mouse_X1, Mouse_X2, Wheel_Up,
 * Wheel_Down, Wheel_Left and Wheel_Right (a wheel notch presses the control
 * for a moment). Without SPEC: WASD is the left
 * stick, the arrows the D-pad, IJKL the right stick, Space is A, Esc is B, C
 * is X, V is Y, Enter is Start, Backspace is Back, Q and E are the
 * shoulders, Z and X the triggers, Left Shift and F the sticks' clicks, Tab
 * is walk.
 *
 * SPEC holds the settings too: ramp_ms=N (0 by default: a stick jumps to its
 * target; else it ramps from its center to its target over N ms, as a thumb
 * pushing a stick does, and comes back at once), walk_percent=N (50 by
 * default: the sticks' deflection with walk held), socd=last|neutral (what
 * two opposite directions held together do, the last pressed or nothing,
 * for every pad; socd_dpad, socd_left_stick and socd_right_stick set one),
 * mouse_stick=off|right|left (off by default: the mouse moves that stick, as
 * a velocity: the faster it moves, the farther the stick, full at 32 pixels
 * per 8 ms at mouse_sensitivity=100, and back to the center when the mouse
 * stops; the keys of that stick win while held).
 *
 * The gamepad takes the mouse when mouse_stick is set or a mouse button or
 * wheel is mapped: the window then captures the pointer, as for a HID mouse
 * (the capture key releases it), and while captured the mouse's motion,
 * buttons and wheel are the gamepad's, unmapped ones dropped.
 *
 * It behaves as a physical gamepad does: the D-pad and the sticks are apart,
 * a stick pushed on a diagonal is as far from its center as on an axis (a
 * round gate), no pad points two opposite ways, a control stays pressed while
 * any of its keys is held, and a stick moves in one report when the gamepad
 * processor takes a stick event.
 */

enum sc_keyboard_gamepad_socd {
    // Of two opposite directions, the last pressed counts
    SC_KEYBOARD_GAMEPAD_SOCD_LAST,
    // Two opposite directions cancel out
    SC_KEYBOARD_GAMEPAD_SOCD_NEUTRAL,
};

enum sc_keyboard_gamepad_mouse_stick {
    SC_KEYBOARD_GAMEPAD_MOUSE_STICK_OFF,
    SC_KEYBOARD_GAMEPAD_MOUSE_STICK_RIGHT,
    SC_KEYBOARD_GAMEPAD_MOUSE_STICK_LEFT,
};

// What a "key" of the gamepad is
enum sc_keyboard_gamepad_input {
    SC_KEYBOARD_GAMEPAD_INPUT_KEY, // code: SDL_Scancode
    SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON, // code: enum sc_mouse_button
    SC_KEYBOARD_GAMEPAD_INPUT_WHEEL, // code: enum sc_keyboard_gamepad_wheel
};

enum sc_keyboard_gamepad_wheel {
    SC_KEYBOARD_GAMEPAD_WHEEL_UP,
    SC_KEYBOARD_GAMEPAD_WHEEL_DOWN,
    SC_KEYBOARD_GAMEPAD_WHEEL_LEFT,
    SC_KEYBOARD_GAMEPAD_WHEEL_RIGHT,
};

struct sc_keyboard_gamepad_control; // a control of the gamepad, private

struct sc_keyboard_gamepad_key {
    enum sc_keyboard_gamepad_input input;
    uint32_t code;
    const struct sc_keyboard_gamepad_control *control;
    // While the key is held on the gamepad, the order of its press (of two
    // opposite directions, the last pressed counts); 0 once released
    uint32_t pressed;
    // A wheel notch's press is released at this time
    uint64_t release_ms;
};

// The owner's timer: arm() is called when a stick starts ramping, and the
// owner then calls sc_keyboard_gamepad_tick() every few milliseconds until it
// returns false. NULL when no one ticks (ramp_ms is then as good as 0).
struct sc_keyboard_gamepad_timer {
    void (*arm)(void *userdata);
    void *userdata;
};

struct sc_keyboard_gamepad {
    struct sc_gamepad_processor *gp;
    struct sc_keyboard_gamepad_key keys[SC_KEYBOARD_GAMEPAD_MAX_KEYS];
    size_t key_count;
    uint32_t press_count;

    // Settings
    uint32_t ramp_ms;
    uint8_t walk_percent;
    enum sc_keyboard_gamepad_socd socd[SC_KEYBOARD_GAMEPAD_PAD_COUNT];
    enum sc_keyboard_gamepad_mouse_stick mouse_stick;
    uint32_t mouse_sensitivity;
    bool has_mouse_keys;

    // The mouse's motion since the last tick, the stick position it gives,
    // and when it last moved
    int32_t mouse_dx;
    int32_t mouse_dy;
    int16_t mouse_x;
    int16_t mouse_y;
    uint64_t mouse_motion_ms;

    // Where each pad points on the device: -1 (left or up), 0 or 1 (right or
    // down) on each axis
    int8_t x[SC_KEYBOARD_GAMEPAD_PAD_COUNT];
    int8_t y[SC_KEYBOARD_GAMEPAD_PAD_COUNT];
    // How far each stick is pushed (0 to INT16_MAX), and the values sent
    int32_t magnitude[SC_KEYBOARD_GAMEPAD_PAD_COUNT];
    int16_t sent_x[SC_KEYBOARD_GAMEPAD_PAD_COUNT];
    int16_t sent_y[SC_KEYBOARD_GAMEPAD_PAD_COUNT];
    // The sticks still ramping toward their target, whether the owner's
    // timer ticks, and the time of the last tick
    bool ramping[SC_KEYBOARD_GAMEPAD_PAD_COUNT];
    bool ticking;
    uint64_t tick_ms;

    const struct sc_keyboard_gamepad_timer *timer;
};

// spec: the keys of each control and the settings, or NULL or "" for the
// defaults. Keys, controls and settings that are not understood are reported
// and skipped, as is a key given to a second control. timer: see
// sc_keyboard_gamepad_timer, or NULL.
void
sc_keyboard_gamepad_init(struct sc_keyboard_gamepad *kg,
                         struct sc_gamepad_processor *gp, const char *spec,
                         const struct sc_keyboard_gamepad_timer *timer);

// Announces the keyboard gamepad to the device
void
sc_keyboard_gamepad_plug(struct sc_keyboard_gamepad *kg);

// Returns true if the key event was a gamepad key, now handled. A press with
// Ctrl, Alt or Super is not one (it types). The release of a held key always
// is, whatever modifier is down by then, so call it for every key release
// before any other handling: a modifier pressed while a gamepad key is held,
// or the keys SDL releases on focus loss with the modifiers still down, would
// otherwise leave the button pressed on the device. The event's timestamp is
// the time a ramp starts from.
bool
sc_keyboard_gamepad_handle_key(struct sc_keyboard_gamepad *kg,
                               const SDL_KeyboardEvent *event);

// Moves the ramping sticks on toward their targets, the mouse's stick with
// the mouse, and releases the wheel's notches, at now_ms (the clock of
// SDL_GetTicks() and of the events' timestamps). Returns whether there is
// more to do, so that the owner ticks again.
bool
sc_keyboard_gamepad_tick(struct sc_keyboard_gamepad *kg, uint64_t now_ms);

// Whether the mouse is the gamepad's: mouse_stick is set, or a mouse button
// or the wheel is mapped. The owner then captures the pointer and hands the
// mouse's events below while it is captured.
bool
sc_keyboard_gamepad_takes_mouse(const struct sc_keyboard_gamepad *kg);

// The mouse moved by (xrel, yrel) at now_ms
void
sc_keyboard_gamepad_handle_mouse_motion(struct sc_keyboard_gamepad *kg,
                                        int32_t xrel, int32_t yrel,
                                        uint64_t now_ms);

// A mouse button went down or up. Returns true if the event was the
// gamepad's: a press always is (an unmapped button is dropped), a release
// only of a button the gamepad holds, so that a button pressed before the
// capture is released where it was pressed.
bool
sc_keyboard_gamepad_handle_mouse_button(struct sc_keyboard_gamepad *kg,
                                        uint32_t button, bool down,
                                        uint64_t now_ms);

// The wheel turned: each notch presses its control for a moment
void
sc_keyboard_gamepad_handle_mouse_wheel(struct sc_keyboard_gamepad *kg,
                                       float hscroll, float vscroll,
                                       uint64_t now_ms);

// Releases every held key, for when the window loses focus
void
sc_keyboard_gamepad_release_all(struct sc_keyboard_gamepad *kg);

#endif
