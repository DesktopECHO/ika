#ifndef SC_IKA_KEYBOARD_TOUCH_H
#define SC_IKA_KEYBOARD_TOUCH_H

#include "common.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <SDL3/SDL.h>

#include "android/input.h"
#include "coords.h"
#include "ika/keyboard_gamepad.h"

#define SC_KEYBOARD_TOUCH_MAX_KEYS 64
#define SC_KEYBOARD_TOUCH_MAX_TAPS 32

// Android takes this many fingers at once (scrcpy's server too)
#define SC_KEYBOARD_TOUCH_MAX_FINGERS 10

// The fingers' pointer ids: a tap's is this plus its index, the joystick's
// and the aim's two come after the taps'. Apart from the mouse's and
// scrcpy's own (SC_POINTER_ID_*), so that the mouse's finger can touch at
// the same time.
#define SC_KEYBOARD_TOUCH_POINTER_ID UINT64_C(0x4B540000)
#define SC_KEYBOARD_TOUCH_JOYSTICK_POINTER_ID \
    (SC_KEYBOARD_TOUCH_POINTER_ID + SC_KEYBOARD_TOUCH_MAX_TAPS)
#define SC_KEYBOARD_TOUCH_AIM_POINTER_ID \
    (SC_KEYBOARD_TOUCH_POINTER_ID + SC_KEYBOARD_TOUCH_MAX_TAPS + 1)
#define SC_KEYBOARD_TOUCH_FINGER_COUNT (SC_KEYBOARD_TOUCH_MAX_TAPS + 3)

// A key's target, when it is not a tap's index: a direction or modifier of
// the joystick
#define SC_KEYBOARD_TOUCH_JOYSTICK_UP (-1)
#define SC_KEYBOARD_TOUCH_JOYSTICK_DOWN (-2)
#define SC_KEYBOARD_TOUCH_JOYSTICK_LEFT (-3)
#define SC_KEYBOARD_TOUCH_JOYSTICK_RIGHT (-4)
#define SC_KEYBOARD_TOUCH_JOYSTICK_WALK (-5)
#define SC_KEYBOARD_TOUCH_JOYSTICK_SPRINT (-6)

/**
 * Keys that touch the screen (--touchkb=FILE), for games that only have
 * on-screen controls.
 *
 * FILE holds a [touch] section of "key key = X Y" lines and "setting =
 * value" lines; a spec is the same as "key/key=X:Y,setting=value" (see
 * sc_keyboard_touch_init_file()). While one of the keys is held, a finger
 * touches the device's display at X:Y, fractions of its width and height
 * (0:0 is the top left corner, 1:1 the bottom right one). Keys are given as
 * in --gamekb's spec: SDL key names with "_" for a space, separated by "/",
 * or the mouse's Mouse_Left, Mouse_Right, Mouse_Middle, Mouse_X1 and
 * Mouse_X2.
 *
 * "key = X Y cast R" is a skill cast, as in MOBAs: while the key is held, the
 * finger touches X:Y and slides toward where the mouse pointer is, seen from
 * cast_center (the player's character, the display's center by default), as
 * far as R (a fraction of the display's height) once the pointer is half the
 * display's height away; releasing the key lifts it, casting there.
 *
 * aspect = W/H is the display's aspect ratio the points were placed at. On a
 * display of another aspect ratio, they move as a game's controls do when it
 * scales its interface with the display's height: a point in the left third
 * keeps its distance from the left edge, one in the right third from the
 * right edge, one in the middle from the center (and from the top, bottom or
 * middle on portrait displays, scaled with the width), measured in display
 * heights (widths), as radii are.
 *
 * Settings:
 *  - joystick=X:Y:R: an on-screen joystick centered at X:Y, R its radius as a
 *    fraction of the display's height. While a direction key is held, a
 *    finger touches its center and slides R away in that direction over
 *    joystick_ramp_ms (60 by default), as a thumb does (on a diagonal, as far
 *    as on an axis); of two opposite directions, the last pressed counts.
 *    joystick_up, joystick_down, joystick_left and joystick_right give its
 *    keys, W, S, A and D by default. While a joystick_walk key is held, the
 *    finger goes joystick_walk_percent of R (50); while a joystick_sprint key
 *    is, joystick_sprint_percent (200), which most games take as sprinting.
 *  - aim=X:Y:R: the mouse looks around, as a finger dragged on the display
 *    from X:Y. When the finger would go R (of the display's height) away, a
 *    second finger touches X:Y and takes the rest of the motion before the
 *    first lifts, so that there is always a finger down and the view turns on
 *    without a jump or a tap. aim_sensitivity=N (1 to 1000, 100 by default)
 *    moves the finger N/100 of the display's pixels per pixel of the mouse.
 *
 * With aim, the window captures the pointer, as for --gamekb's mouse_stick
 * (the capture key releases it), and while it is captured the mouse's
 * buttons are the keys of their taps, unmapped ones and the wheel dropped.
 * Without aim, or while the pointer is free, the left button is a finger of
 * its own, which taps where the pointer is, and the other buttons touch
 * their points if they have one.
 *
 * Any key can touch, Ctrl, Shift and Right Alt among them, but for the
 * shortcut modifiers (shortcut_mods, Left Alt and Left Super in Ika), and a
 * key pressed with one of them is a shortcut, not a touch. A held key is
 * released whatever modifier is down by then, and every key when the window
 * loses the focus, so that no finger stays on the display. No more than
 * SC_KEYBOARD_TOUCH_MAX_FINGERS fingers touch at once: a key that would add
 * one more does nothing, and says so once.
 */

struct sc_keyboard_touch_sink {
    // The device's display, in pixels
    struct sc_size (*get_size)(void *userdata);
    // A finger goes down, moves or goes up (AMOTION_EVENT_ACTION_DOWN, _MOVE
    // or _UP) at point, in the display's pixels
    void (*touch)(void *userdata, enum android_motionevent_action action,
                  uint64_t pointer_id, struct sc_point point);
    void *userdata;
};

// A point on the display, as fractions of its width and height (at the
// layout's aspect ratio), and a radius as a fraction of its height
struct sc_keyboard_touch_point {
    float x;
    float y;
    float r;
};

enum sc_keyboard_touch_kind {
    SC_KEYBOARD_TOUCH_TAP,
    SC_KEYBOARD_TOUCH_CAST,
};

struct sc_keyboard_touch_key {
    enum sc_keyboard_gamepad_input input;
    uint32_t code;
    // >= 0: the index of its tap; else SC_KEYBOARD_TOUCH_JOYSTICK_*
    int16_t target;
    // While held, the order of its press (of two opposite directions, the
    // last pressed counts); 0 once released
    uint32_t pressed;
};

struct sc_keyboard_touch {
    const struct sc_keyboard_touch_sink *sink;
    // The owner's timer, for the joystick's ramp, or NULL (no ramp)
    const struct sc_keyboard_gamepad_timer *timer;
    // The window's shortcut modifiers (SDL_KMOD_*), set by the owner
    uint16_t shortcut_mods;

    struct sc_keyboard_touch_key keys[SC_KEYBOARD_TOUCH_MAX_KEYS];
    size_t key_count;
    uint32_t press_count;

    // The layout's aspect ratio (width / height), 0 if not known
    float aspect;

    // r: the cast's radius, for SC_KEYBOARD_TOUCH_CAST
    struct sc_keyboard_touch_point taps[SC_KEYBOARD_TOUCH_MAX_TAPS];
    enum sc_keyboard_touch_kind kinds[SC_KEYBOARD_TOUCH_MAX_TAPS];
    size_t tap_count;
    // How many of each tap's keys are held: its finger is down while any is
    uint8_t tap_held[SC_KEYBOARD_TOUCH_MAX_TAPS];
    // Where each tap's finger is (a cast's slides), in the display's pixels
    struct sc_point tap_at[SC_KEYBOARD_TOUCH_MAX_TAPS];

    // The player's character, for skill casts, and the mouse pointer on the
    // display (pixels), as the owner last gave it
    struct sc_keyboard_touch_point cast_center;
    bool has_cursor;
    float cursor_x;
    float cursor_y;

    bool has_joystick;
    struct sc_keyboard_touch_point joystick;
    uint32_t joystick_ramp_ms;
    uint32_t joystick_walk_percent;
    uint32_t joystick_sprint_percent;
    bool joystick_down;
    struct sc_point joystick_at;
    // The ramp from the center, since the first direction key went down
    bool joystick_ramping;
    uint64_t joystick_start_ms;
    uint64_t now_ms;

    bool has_aim;
    struct sc_keyboard_touch_point aim;
    uint32_t aim_sensitivity;
    bool aim_down;
    // The aim's finger (0 or 1, of two that take turns) and where it is, in
    // the display's pixels
    unsigned aim_finger;
    float aim_x;
    float aim_y;

    // The fingers down, by pointer id from SC_KEYBOARD_TOUCH_POINTER_ID
    uint64_t fingers_down;
    bool told_too_many;
};

// spec: see above, or NULL or "". Keys and settings that are not understood
// are reported and skipped, as is a key given twice. The sink is set before
// the first event.
void
sc_keyboard_touch_init(struct sc_keyboard_touch *kt, const char *spec);

// Reads the [touch] section of the file at path: "key key = X Y" lines, keys
// separated by blanks, values by blanks or commas, and "setting = value"
// lines (the joystick's keys separated by blanks), as
// sc_keyboard_touch_init() reads a spec. A file that does not exist gives no
// keys (the editor makes one).
void
sc_keyboard_touch_init_file(struct sc_keyboard_touch *kt, const char *path);

// Writes the keys and settings to the file at path, as
// sc_keyboard_touch_init_file() reads them. Returns false on failure.
bool
sc_keyboard_touch_save(const struct sc_keyboard_touch *kt, const char *path);

// The name of a key, as a spec gives it ("Left_Shift", "Mouse_Right"), or
// with spaces for a label (with_spaces)
void
sc_keyboard_touch_key_name(const struct sc_keyboard_touch_key *key,
                           bool with_spaces, char *buf, size_t size);

// Where the point p is on a display of the given size, in pixels, as the
// layout's aspect ratio says (see above)
float
sc_keyboard_touch_px_x(const struct sc_keyboard_touch *kt,
                       const struct sc_keyboard_touch_point *p,
                       struct sc_size size);
float
sc_keyboard_touch_px_y(const struct sc_keyboard_touch *kt,
                       const struct sc_keyboard_touch_point *p,
                       struct sc_size size);

// Editing, with no finger down (release them all first):

// Moves every point to where it is on a display of the given size, and
// makes that display's aspect ratio the layout's, so that the editor places
// the points as they are shown
void
sc_keyboard_touch_rebase(struct sc_keyboard_touch *kt, struct sc_size size);

// Adds a tap with no key at x:y; returns its index, or -1 if there are too
// many
int
sc_keyboard_touch_add_tap(struct sc_keyboard_touch *kt, float x, float y);

// Removes the tap at index, and its keys
void
sc_keyboard_touch_remove_tap(struct sc_keyboard_touch *kt, size_t index);

// Gives the key (input, code) to target (a tap's index or a target of the
// joystick), taking it from the target it had; a tap left with no key, other
// than target, is removed. A key that target already has is taken from it
// instead. Returns target's index after any removal (target itself for the
// joystick), or -1 if there are too many keys.
int
sc_keyboard_touch_bind(struct sc_keyboard_touch *kt,
                       enum sc_keyboard_gamepad_input input, uint32_t code,
                       int target);

// Removes the taps with no key
void
sc_keyboard_touch_prune(struct sc_keyboard_touch *kt);

// Sets the joystick (with its default keys for the directions that have
// none, where free) or the aim at x:y:r, or removes it (and the joystick's
// keys) with set false
void
sc_keyboard_touch_set_joystick(struct sc_keyboard_touch *kt, bool set,
                               float x, float y, float r);
void
sc_keyboard_touch_set_aim(struct sc_keyboard_touch *kt, bool set, float x,
                          float y, float r);

// Returns true if the key event was one of a tap or of the joystick, now
// handled; same rules as sc_keyboard_gamepad_handle_key(): call it for every
// key release before any other handling.
bool
sc_keyboard_touch_handle_key(struct sc_keyboard_touch *kt,
                             const SDL_KeyboardEvent *event);

// Moves the joystick's ramp on at now_ms (the clock of SDL_GetTicks() and of
// the events' timestamps); returns whether to tick again
bool
sc_keyboard_touch_tick(struct sc_keyboard_touch *kt, uint64_t now_ms);

// Whether the mouse aims (aim is set): the owner then captures the pointer
// and hands the mouse's events below while it is captured.
bool
sc_keyboard_touch_takes_mouse(const struct sc_keyboard_touch *kt);

// The captured mouse moved by (xrel, yrel)
void
sc_keyboard_touch_handle_mouse_motion(struct sc_keyboard_touch *kt,
                                      float xrel, float yrel);

// The free mouse pointer is at (x, y) on the display, in pixels, or off it
// (has false): skill casts slide toward it
void
sc_keyboard_touch_set_cursor(struct sc_keyboard_touch *kt, bool has, float x,
                             float y);

// A mouse button went down or up. While the pointer is captured, every
// button is the touch keys': a press always returns true (an unmapped button
// is dropped). While it is free (captured false), only the buttons other
// than the left one that are touch keys are. A release is the touch keys'
// only for a button they hold.
bool
sc_keyboard_touch_handle_mouse_button(struct sc_keyboard_touch *kt,
                                      uint32_t button, bool down,
                                      bool captured);

// Lifts every finger, for when the window loses the focus
void
sc_keyboard_touch_release_all(struct sc_keyboard_touch *kt);

// Lifts the fingers of the mouse's buttons and the aim's, for when the window
// lets the pointer go
void
sc_keyboard_touch_release_mouse(struct sc_keyboard_touch *kt);

#endif
