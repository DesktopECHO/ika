#ifndef SC_IKA_TOUCH_EDITOR_H
#define SC_IKA_TOUCH_EDITOR_H

#include "common.h"

#include <stdbool.h>
#include <SDL3/SDL.h>

#include "ika/keyboard_touch.h"

/**
 * The touch keys' editor, over the game in its window (MOD+t, or
 * --touchkb-edit at start).
 *
 * The game keeps running underneath, and gets no input meanwhile. Each touch
 * key's point is a circle labelled with its keys; the joystick and the aim
 * are rings of their radius. A toolbar at the top adds the joystick and the
 * aim, removes the selected control, and closes the editor.
 *
 * - A click on the display where there is no control adds a point there and
 *   selects it; a click on a control selects it, and dragging moves it (the
 *   edge of a ring resizes it).
 * - A key pressed while a point is selected is given to it, taken from any
 *   control that had it; pressed again, it is taken off. The right, middle
 *   and side buttons of the mouse are given the same way, clicked on the
 *   selected point; the left button with the toolbar's "Left click".
 * - With the joystick selected, keys are given to its directions in turn,
 *   up, down, left and right, then to its walk and sprint modifiers; the
 *   wheel over the aim sets its sensitivity.
 * - "Skill cast" makes the selected point a skill cast, or a tap again; its
 *   ring is its reach, and the character marker it adds (where casts aim
 *   from) can be dragged.
 * - Delete removes the selected control; Escape selects nothing.
 * - Keys pressed with the shortcut modifier (MOD) are not the editor's, so
 *   that the window's shortcuts work, MOD+t among them, which closes the
 *   editor; MOD itself is not a touch key.
 *
 * Closing it drops the points left without a key and saves the touch keys to
 * their file.
 */

enum sc_touch_editor_selection {
    SC_TOUCH_EDITOR_SELECTION_NONE,
    SC_TOUCH_EDITOR_SELECTION_TAP,
    SC_TOUCH_EDITOR_SELECTION_JOYSTICK,
    SC_TOUCH_EDITOR_SELECTION_AIM,
    SC_TOUCH_EDITOR_SELECTION_CAST_CENTER,
};

enum sc_touch_editor_drag {
    SC_TOUCH_EDITOR_DRAG_NONE,
    SC_TOUCH_EDITOR_DRAG_MOVE,
    SC_TOUCH_EDITOR_DRAG_RADIUS,
};

#define SC_TOUCH_EDITOR_BUTTON_COUNT 6

struct sc_touch_editor {
    struct sc_keyboard_touch *kt;
    const char *path;
    // The window's shortcut modifiers (SDL_KMOD_*), set by the owner
    uint16_t shortcut_mods;
    bool active;
    bool changed;

    enum sc_touch_editor_selection selection;
    int tap; // the selected tap, with SC_TOUCH_EDITOR_SELECTION_TAP
    // The joystick target the next key goes to: 0 to 5, up, down, left,
    // right, walk, sprint
    int direction;

    enum sc_touch_editor_drag drag;
    // From the pointer to the dragged control's center, in window points
    float drag_dx;
    float drag_dy;

    // The device's display in the window, in window points, and the window's
    // pixel density, as the screen gives them before each event and render
    SDL_FRect view;
    float density;
    // The device's display, in pixels
    struct sc_size device;

    // The controls are shown, faintly, over the game while it is played
    // (MOD+Shift+t), the editor closed
    bool hints;

    // The toolbar and its buttons, in window points, as last drawn
    SDL_FRect bar;
    SDL_FRect buttons[SC_TOUCH_EDITOR_BUTTON_COUNT];
    bool has_buttons;

    // Done was clicked: the owner closes the editor, as for MOD+t
    bool close_requested;
};

// path: the touch keys' file, where closing the editor saves them
void
sc_touch_editor_init(struct sc_touch_editor *te, struct sc_keyboard_touch *kt,
                     const char *path);

// Opens the editor on a device display of the given size; the owner lifts
// every finger first
void
sc_touch_editor_open(struct sc_touch_editor *te, struct sc_size device);

// Closes it, and saves the touch keys if they changed. Returns false if they
// could not be saved.
bool
sc_touch_editor_close(struct sc_touch_editor *te);

static inline bool
sc_touch_editor_is_open(const struct sc_touch_editor *te) {
    return te->active;
}

// Where the device's display is in the window (window points), the window's
// pixel density, and the device display's size: while the editor is open,
// a new size moves the points to where they are shown on it
void
sc_touch_editor_set_view(struct sc_touch_editor *te, SDL_FRect view,
                         float density, struct sc_size device);

// Handles an input event while the editor is open: returns true if it was
// the editor's (draw again), false if it is not (a shortcut: a key pressed
// with the shortcut modifier, or F11).
bool
sc_touch_editor_handle_event(struct sc_touch_editor *te,
                             const SDL_Event *event);

// Draws the editor over the window's content, in the renderer's pixels
void
sc_touch_editor_render(struct sc_touch_editor *te, SDL_Renderer *renderer);

// Draws the controls' keys, faintly, over the game being played (hints)
void
sc_touch_editor_render_hints(struct sc_touch_editor *te,
                             SDL_Renderer *renderer);

#endif
