#include "common.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "ika/keyboard_gamepad.h"

// A gamepad processor that keeps the state of the device's gamepad, and checks
// after each event what a physical gamepad cannot do: point its D-pad two
// opposite ways, or push a stick out of its round gate
struct recorder {
    struct sc_gamepad_processor gp;
    bool added;
    uint32_t buttons; // 1 << enum sc_gamepad_button
    int16_t axes[6]; // by enum sc_gamepad_axis
    unsigned events;
    unsigned stick_events;
};

static struct recorder *
recorder_of(struct sc_gamepad_processor *gp) {
    return container_of(gp, struct recorder, gp);
}

static bool
button_down(const struct recorder *r, enum sc_gamepad_button button) {
    return r->buttons & (UINT32_C(1) << button);
}

static void
check_stick(const struct recorder *r, enum sc_gamepad_axis ax,
            enum sc_gamepad_axis ay) {
    int64_t x = r->axes[ax];
    int64_t y = r->axes[ay];
    assert(x * x + y * y <= INT64_C(32768) * 32768);
}

static void
check(const struct recorder *r) {
    assert(!(button_down(r, SC_GAMEPAD_BUTTON_DPAD_UP)
             && button_down(r, SC_GAMEPAD_BUTTON_DPAD_DOWN)));
    assert(!(button_down(r, SC_GAMEPAD_BUTTON_DPAD_LEFT)
             && button_down(r, SC_GAMEPAD_BUTTON_DPAD_RIGHT)));
    check_stick(r, SC_GAMEPAD_AXIS_LEFTX, SC_GAMEPAD_AXIS_LEFTY);
    check_stick(r, SC_GAMEPAD_AXIS_RIGHTX, SC_GAMEPAD_AXIS_RIGHTY);
}

static void
recorder_added(struct sc_gamepad_processor *gp,
               const struct sc_gamepad_device_event *event) {
    assert(event->gamepad_id == SC_KEYBOARD_GAMEPAD_ID);
    recorder_of(gp)->added = true;
}

static void
recorder_removed(struct sc_gamepad_processor *gp,
                 const struct sc_gamepad_device_event *event) {
    (void) gp;
    (void) event;
    assert(!"the keyboard gamepad is never removed");
}

static void
recorder_axis(struct sc_gamepad_processor *gp,
              const struct sc_gamepad_axis_event *event) {
    struct recorder *r = recorder_of(gp);
    assert(event->gamepad_id == SC_KEYBOARD_GAMEPAD_ID);
    assert(event->axis >= 0 && event->axis < 6);
    r->axes[event->axis] = event->value;
    r->events++;
    check(r);
}

static void
recorder_button(struct sc_gamepad_processor *gp,
                const struct sc_gamepad_button_event *event) {
    struct recorder *r = recorder_of(gp);
    assert(event->gamepad_id == SC_KEYBOARD_GAMEPAD_ID);
    uint32_t bit = UINT32_C(1) << event->button;
    if (event->action == SC_ACTION_DOWN) {
        assert(!(r->buttons & bit));
        r->buttons |= bit;
    } else {
        assert(r->buttons & bit);
        r->buttons &= ~bit;
    }
    r->events++;
    check(r);
}

static void
recorder_stick(struct sc_gamepad_processor *gp,
               const struct sc_gamepad_stick_event *event) {
    struct recorder *r = recorder_of(gp);
    assert(event->gamepad_id == SC_KEYBOARD_GAMEPAD_ID);
    if (event->stick == SC_GAMEPAD_STICK_LEFT) {
        r->axes[SC_GAMEPAD_AXIS_LEFTX] = event->x;
        r->axes[SC_GAMEPAD_AXIS_LEFTY] = event->y;
    } else {
        assert(event->stick == SC_GAMEPAD_STICK_RIGHT);
        r->axes[SC_GAMEPAD_AXIS_RIGHTX] = event->x;
        r->axes[SC_GAMEPAD_AXIS_RIGHTY] = event->y;
    }
    r->events++;
    r->stick_events++;
    check(r);
}

// A processor that takes a stick in one event, as the UHID gamepad does
static const struct sc_gamepad_processor_ops recorder_ops = {
    .process_gamepad_added = recorder_added,
    .process_gamepad_removed = recorder_removed,
    .process_gamepad_axis = recorder_axis,
    .process_gamepad_button = recorder_button,
    .process_gamepad_stick = recorder_stick,
};

// One that takes an axis at a time
static const struct sc_gamepad_processor_ops axis_recorder_ops = {
    .process_gamepad_added = recorder_added,
    .process_gamepad_removed = recorder_removed,
    .process_gamepad_axis = recorder_axis,
    .process_gamepad_button = recorder_button,
    .process_gamepad_stick = NULL,
};

static struct recorder r;
static struct sc_keyboard_gamepad kg;
static unsigned armed;
static uint64_t now_ms;

static void
timer_arm(void *userdata) {
    assert(userdata == &kg);
    armed++;
}

static const struct sc_keyboard_gamepad_timer timer = {
    .arm = timer_arm,
    .userdata = &kg,
};

static void
setup_with(const char *spec, const struct sc_gamepad_processor_ops *ops) {
    memset(&r, 0, sizeof(r));
    r.gp.ops = ops;
    armed = 0;
    now_ms = 0;
    sc_keyboard_gamepad_init(&kg, &r.gp, spec, &timer);
    sc_keyboard_gamepad_plug(&kg);
    assert(r.added);
}

static void
setup(const char *spec) {
    setup_with(spec, &recorder_ops);
}

static bool
key_event(SDL_Scancode scancode, bool down, SDL_Keymod mod, bool repeat) {
    SDL_KeyboardEvent event = {
        .type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP,
        .timestamp = now_ms * 1000000,
        .scancode = scancode,
        .mod = mod,
        .down = down,
        .repeat = repeat,
    };
    return sc_keyboard_gamepad_handle_key(&kg, &event);
}

static void
press(SDL_Scancode scancode) {
    bool handled = key_event(scancode, true, SDL_KMOD_NONE, false);
    assert(handled);
    (void) handled;
}

static void
release(SDL_Scancode scancode) {
    bool handled = key_event(scancode, false, SDL_KMOD_NONE, false);
    assert(handled);
    (void) handled;
}

static bool
tick(uint64_t at_ms) {
    now_ms = at_ms;
    return sc_keyboard_gamepad_tick(&kg, at_ms);
}

static void
assert_neutral(void) {
    assert(!r.buttons);
    for (int i = 0; i < 6; ++i) {
        assert(!r.axes[i]);
    }
}

static void test_stick_and_dpad_apart(void) {
    setup(NULL);

    press(SDL_SCANCODE_W);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTX]);
    assert(!r.buttons);
    release(SDL_SCANCODE_W);
    assert_neutral();

    press(SDL_SCANCODE_UP);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_UP));
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTY]);
    release(SDL_SCANCODE_UP);
    assert_neutral();

    press(SDL_SCANCODE_L);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTX] == INT16_MAX);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTX]);
    release(SDL_SCANCODE_L);
    assert_neutral();
}

static void test_stick_diagonal_round_gate(void) {
    setup(NULL);

    press(SDL_SCANCODE_W);
    press(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == -23170);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -23170);
    release(SDL_SCANCODE_W);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MIN);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTY]);
    press(SDL_SCANCODE_S);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == -23170);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == 23170);
    release(SDL_SCANCODE_A);
    release(SDL_SCANCODE_S);
    assert_neutral();
}

static void test_stick_in_one_report(void) {
    // A processor that takes stick events gets one per move
    setup(NULL);
    press(SDL_SCANCODE_W);
    assert(r.events == 1 && r.stick_events == 1);
    press(SDL_SCANCODE_A);
    assert(r.events == 2 && r.stick_events == 2);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == -23170);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -23170);
    release(SDL_SCANCODE_A);
    release(SDL_SCANCODE_W);
    assert(r.events == 4);
    assert_neutral();

    // One that does not gets the two axes, inside the gate between them
    // (checked on each event)
    setup_with(NULL, &axis_recorder_ops);
    press(SDL_SCANCODE_W);
    assert(r.events == 1 && !r.stick_events);
    press(SDL_SCANCODE_A);
    assert(r.events == 3);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == -23170);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -23170);
    release(SDL_SCANCODE_W);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MIN);
    release(SDL_SCANCODE_A);
    assert_neutral();
}

static void test_last_direction_counts(void) {
    setup(NULL);

    // Stick: A then D goes right, back left when D is released
    press(SDL_SCANCODE_A);
    press(SDL_SCANCODE_D);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MAX);
    release(SDL_SCANCODE_D);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MIN);
    press(SDL_SCANCODE_D);
    release(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MAX);
    release(SDL_SCANCODE_D);
    assert_neutral();

    // Whatever their order in the spec: D then A goes left
    press(SDL_SCANCODE_D);
    press(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MIN);
    release(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MAX);
    release(SDL_SCANCODE_D);
    assert_neutral();

    // D-pad: the same, never both buttons at once (checked on each event)
    press(SDL_SCANCODE_LEFT);
    press(SDL_SCANCODE_RIGHT);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_RIGHT));
    assert(!button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));
    release(SDL_SCANCODE_RIGHT);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));
    press(SDL_SCANCODE_DOWN);
    press(SDL_SCANCODE_UP);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_UP));
    release(SDL_SCANCODE_UP);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_DOWN));
    release(SDL_SCANCODE_DOWN);
    press(SDL_SCANCODE_UP);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_UP));
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));
    release(SDL_SCANCODE_LEFT);
    release(SDL_SCANCODE_UP);
    assert_neutral();
}

static void test_socd_neutral(void) {
    // Two opposite directions cancel out on every pad
    setup("left_stick_left=A,left_stick_right=D,dpad_left=Left,"
          "dpad_right=Right,socd=neutral");
    press(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MIN);
    press(SDL_SCANCODE_D);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTX]);
    release(SDL_SCANCODE_D);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MIN);
    release(SDL_SCANCODE_A);
    press(SDL_SCANCODE_LEFT);
    press(SDL_SCANCODE_RIGHT);
    assert(!r.buttons);
    release(SDL_SCANCODE_LEFT);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_RIGHT));
    release(SDL_SCANCODE_RIGHT);
    assert_neutral();

    // Or on one pad: the D-pad keeps the last pressed
    setup("left_stick_left=A,left_stick_right=D,dpad_left=Left,"
          "dpad_right=Right,socd=neutral,socd_dpad=last");
    press(SDL_SCANCODE_A);
    press(SDL_SCANCODE_D);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTX]);
    press(SDL_SCANCODE_LEFT);
    press(SDL_SCANCODE_RIGHT);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_RIGHT));
    sc_keyboard_gamepad_release_all(&kg);
    assert_neutral();

    setup("left_stick_left=A,left_stick_right=D,right_stick_left=J,"
          "right_stick_right=L,socd_left_stick=neutral");
    press(SDL_SCANCODE_A);
    press(SDL_SCANCODE_D);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTX]);
    press(SDL_SCANCODE_J);
    press(SDL_SCANCODE_L);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTX] == INT16_MAX);
    sc_keyboard_gamepad_release_all(&kg);
    assert_neutral();
}

static void test_ramp(void) {
    // Without a ramp (the default), a stick jumps to its target and no timer
    // is armed
    setup(NULL);
    press(SDL_SCANCODE_W);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    assert(!armed);
    assert(!sc_keyboard_gamepad_tick(&kg, 100));
    release(SDL_SCANCODE_W);

    // With one, the key pushes the stick one tick's worth at once, the timer
    // is armed, and the ticks carry it on to full over ramp_ms
    setup("left_stick_up=W,left_stick_left=A,walk=Tab,ramp_ms=100");
    press(SDL_SCANCODE_W);
    assert(armed == 1);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -2621); // 8 ms of 100
    assert(tick(50));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -(2621 + 16383));
    assert(!tick(100));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    assert(!tick(108));
    assert(r.events == 3);
    assert(armed == 1);

    // Back to the center at once
    release(SDL_SCANCODE_W);
    assert_neutral();

    // A direction change while ramping keeps the deflection and ramps on
    now_ms = 200;
    press(SDL_SCANCODE_W);
    assert(armed == 2);
    now_ms = 204;
    press(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == -1853); // 2621 on a diagonal
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -1853);
    assert(!tick(300));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == -23170);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -23170);
    // Letting one direction go keeps the other at full, at once
    release(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTX]);
    release(SDL_SCANCODE_W);
    assert_neutral();

    // A ramp shorter than a tick is as good as none
    setup("left_stick_up=W,ramp_ms=5");
    press(SDL_SCANCODE_W);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    assert(!armed);
    release(SDL_SCANCODE_W);
}

static void test_walk(void) {
    // Tab held caps the sticks at walk_percent, 50 by default
    setup(NULL);
    press(SDL_SCANCODE_TAB);
    assert(!r.events);
    press(SDL_SCANCODE_W);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -16383);
    press(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == -11584); // 16383 on a diagonal
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -11584);
    release(SDL_SCANCODE_A);
    release(SDL_SCANCODE_TAB);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    press(SDL_SCANCODE_TAB);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == -16383);
    release(SDL_SCANCODE_W);
    release(SDL_SCANCODE_TAB);
    assert_neutral();

    // walk_percent sets the cap; with a ramp, walk pulls a pushed stick down
    // at once and letting it go ramps the stick on up
    setup("left_stick_right=D,walk=Tab/Left_Ctrl,walk_percent=30,"
          "ramp_ms=100");
    press(SDL_SCANCODE_D);
    assert(!tick(100));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MAX);
    press(SDL_SCANCODE_LCTRL);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == 9830); // 30% of 32767
    assert(!tick(200));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == 9830);
    now_ms = 200;
    release(SDL_SCANCODE_LCTRL);
    assert(armed == 2);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == 9830 + 2621);
    assert(!tick(300));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MAX);
    release(SDL_SCANCODE_D);
    assert_neutral();
}

static void test_control_held_by_any_key(void) {
    setup(NULL);

    press(SDL_SCANCODE_RETURN);
    press(SDL_SCANCODE_KP_ENTER);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_START));
    release(SDL_SCANCODE_RETURN);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_START));
    release(SDL_SCANCODE_KP_ENTER);
    assert(!button_down(&r, SC_GAMEPAD_BUTTON_START));

    setup("left_trigger=Z/1,left_stick_up=W/Up");
    press(SDL_SCANCODE_Z);
    press(SDL_SCANCODE_1);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFT_TRIGGER] == INT16_MAX);
    release(SDL_SCANCODE_Z);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFT_TRIGGER] == INT16_MAX);
    release(SDL_SCANCODE_1);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFT_TRIGGER]);

    press(SDL_SCANCODE_W);
    press(SDL_SCANCODE_UP);
    unsigned events = r.events;
    release(SDL_SCANCODE_W);
    assert(r.events == events);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    release(SDL_SCANCODE_UP);
    assert_neutral();
}

static void test_default_buttons(void) {
    setup(NULL);

    static const struct {
        SDL_Scancode key;
        enum sc_gamepad_button button;
    } buttons[] = {
        {SDL_SCANCODE_SPACE, SC_GAMEPAD_BUTTON_SOUTH},
        {SDL_SCANCODE_ESCAPE, SC_GAMEPAD_BUTTON_EAST},
        {SDL_SCANCODE_C, SC_GAMEPAD_BUTTON_WEST},
        {SDL_SCANCODE_V, SC_GAMEPAD_BUTTON_NORTH},
        {SDL_SCANCODE_BACKSPACE, SC_GAMEPAD_BUTTON_BACK},
        {SDL_SCANCODE_Q, SC_GAMEPAD_BUTTON_LEFT_SHOULDER},
        {SDL_SCANCODE_E, SC_GAMEPAD_BUTTON_RIGHT_SHOULDER},
        {SDL_SCANCODE_LSHIFT, SC_GAMEPAD_BUTTON_LEFT_STICK},
        {SDL_SCANCODE_F, SC_GAMEPAD_BUTTON_RIGHT_STICK},
    };
    for (size_t i = 0; i < ARRAY_LEN(buttons); ++i) {
        press(buttons[i].key);
        assert(r.buttons == UINT32_C(1) << buttons[i].button);
        release(buttons[i].key);
        assert_neutral();
    }

    press(SDL_SCANCODE_X);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHT_TRIGGER] == INT16_MAX);
    release(SDL_SCANCODE_X);
    assert_neutral();
}

static void test_modifiers_and_repeats(void) {
    setup(NULL);

    // Ctrl+W types; Shift+W moves (Shift is no shortcut modifier)
    assert(!key_event(SDL_SCANCODE_W, true, SDL_KMOD_LCTRL, false));
    assert(!key_event(SDL_SCANCODE_W, false, SDL_KMOD_LCTRL, false));
    assert(!r.events);
    assert(key_event(SDL_SCANCODE_W, true, SDL_KMOD_LSHIFT, false));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);

    // Repeats send nothing; the release goes through whatever modifier
    unsigned events = r.events;
    assert(key_event(SDL_SCANCODE_W, true, SDL_KMOD_LALT, true));
    assert(r.events == events);
    assert(key_event(SDL_SCANCODE_W, false, SDL_KMOD_LALT, false));
    assert_neutral();

    // A key that is not a gamepad key types
    assert(!key_event(SDL_SCANCODE_M, true, SDL_KMOD_NONE, false));
}

static void test_release_all(void) {
    setup(NULL);

    press(SDL_SCANCODE_W);
    press(SDL_SCANCODE_D);
    press(SDL_SCANCODE_LEFT);
    press(SDL_SCANCODE_DOWN);
    press(SDL_SCANCODE_I);
    press(SDL_SCANCODE_SPACE);
    press(SDL_SCANCODE_Z);
    press(SDL_SCANCODE_TAB);
    sc_keyboard_gamepad_release_all(&kg);
    assert_neutral();

    // Released keys are free again
    press(SDL_SCANCODE_W);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);

    // A ramp interrupted by the release stops
    setup("left_stick_up=W,ramp_ms=100");
    press(SDL_SCANCODE_W);
    sc_keyboard_gamepad_release_all(&kg);
    assert_neutral();
    assert(!tick(50));
    assert_neutral();
}

static void test_mouse_buttons_and_wheel(void) {
    // Mouse buttons are keys like any other; the gamepad takes the mouse only
    // with mouse_stick set, not for its buttons and wheel alone
    setup(NULL);
    assert(!sc_keyboard_gamepad_takes_mouse(&kg));
    setup("a=Mouse_Left,right_trigger=mouse_right,left_shoulder=Wheel_Up,"
          "right_shoulder=Wheel_Down,b=Mouse_X2");
    assert(!sc_keyboard_gamepad_takes_mouse(&kg));
    setup("a=Mouse_Left,right_trigger=mouse_right,left_shoulder=Wheel_Up,"
          "right_shoulder=Wheel_Down,b=Mouse_X2,mouse_stick=off");
    assert(!sc_keyboard_gamepad_takes_mouse(&kg));
    setup("a=Mouse_Left,right_trigger=mouse_right,left_shoulder=Wheel_Up,"
          "right_shoulder=Wheel_Down,b=Mouse_X2,mouse_stick=right");
    assert(sc_keyboard_gamepad_takes_mouse(&kg));
    assert(kg.key_count == 5);

    assert(sc_keyboard_gamepad_handle_mouse_button(&kg, SC_MOUSE_BUTTON_LEFT,
                                                   true, 0));
    assert(button_down(&r, SC_GAMEPAD_BUTTON_SOUTH));
    assert(sc_keyboard_gamepad_handle_mouse_button(&kg, SC_MOUSE_BUTTON_LEFT,
                                                   false, 0));
    assert_neutral();
    assert(sc_keyboard_gamepad_handle_mouse_button(&kg, SC_MOUSE_BUTTON_RIGHT,
                                                   true, 0));
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHT_TRIGGER] == INT16_MAX);
    assert(sc_keyboard_gamepad_handle_mouse_button(&kg, SC_MOUSE_BUTTON_RIGHT,
                                                   false, 0));
    assert_neutral();

    // An unmapped button's press is the gamepad's (dropped), its release is
    // not, nor the release of a button the gamepad does not hold
    unsigned events = r.events;
    assert(sc_keyboard_gamepad_handle_mouse_button(&kg, SC_MOUSE_BUTTON_MIDDLE,
                                                   true, 0));
    assert(!sc_keyboard_gamepad_handle_mouse_button(&kg,
                                                    SC_MOUSE_BUTTON_MIDDLE,
                                                    false, 0));
    assert(!sc_keyboard_gamepad_handle_mouse_button(&kg, SC_MOUSE_BUTTON_LEFT,
                                                    false, 0));
    assert(r.events == events);

    // A wheel notch presses its control for 40 ms, through the timer
    sc_keyboard_gamepad_handle_mouse_wheel(&kg, 0, 1, 100);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_LEFT_SHOULDER));
    assert(armed == 1);
    assert(tick(120));
    assert(button_down(&r, SC_GAMEPAD_BUTTON_LEFT_SHOULDER));
    // Another notch meanwhile holds it longer
    sc_keyboard_gamepad_handle_mouse_wheel(&kg, 0, 2, 130);
    assert(tick(150));
    assert(button_down(&r, SC_GAMEPAD_BUTTON_LEFT_SHOULDER));
    assert(!tick(170));
    assert_neutral();
    // Down, and the horizontal wheel without a key
    sc_keyboard_gamepad_handle_mouse_wheel(&kg, 1, -1, 200);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_RIGHT_SHOULDER));
    assert(!tick(240));
    assert_neutral();
    // Released with the rest
    sc_keyboard_gamepad_handle_mouse_wheel(&kg, 0, -1, 300);
    sc_keyboard_gamepad_release_all(&kg);
    assert_neutral();
    assert(!tick(400));
}

static void test_mouse_stick(void) {
    // Off by default: motion does nothing
    setup(NULL);
    sc_keyboard_gamepad_handle_mouse_motion(&kg, 10, 0, 0);
    assert(!armed);
    assert(!r.events);

    // The mouse moves the right stick as fast as it moves: 32 px per 8 ms
    // is full at 100%
    setup("right_stick_up=I,right_stick_left=J,mouse_stick=right");
    assert(sc_keyboard_gamepad_takes_mouse(&kg));
    sc_keyboard_gamepad_handle_mouse_motion(&kg, 16, 0, 0);
    assert(armed == 1);
    assert(!r.events); // at the next tick, with the whole tick's motion
    assert(tick(8));
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTX] == 16383);
    assert(!r.axes[SC_GAMEPAD_AXIS_RIGHTY]);
    sc_keyboard_gamepad_handle_mouse_motion(&kg, 0, -64, 10);
    assert(tick(16));
    assert(!r.axes[SC_GAMEPAD_AXIS_RIGHTX]);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTY] <= -32700); // clamped to the gate
    // A diagonal stays in the gate
    sc_keyboard_gamepad_handle_mouse_motion(&kg, 64, 64, 20);
    assert(tick(24));
    check_stick(&r, SC_GAMEPAD_AXIS_RIGHTX, SC_GAMEPAD_AXIS_RIGHTY);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTX] > 23000
           && r.axes[SC_GAMEPAD_AXIS_RIGHTY] > 23000);
    // No motion: the stick holds for 24 ms, then comes back
    assert(tick(32));
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTX] > 23000);
    assert(tick(40));
    assert(!tick(48));
    assert_neutral();
    assert(armed == 1);

    // The stick's keys win while held; the mouse comes back when they go
    sc_keyboard_gamepad_handle_mouse_motion(&kg, 32, 0, 100);
    assert(armed == 2);
    assert(tick(108));
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTX] == INT16_MAX);
    now_ms = 110;
    press(SDL_SCANCODE_I);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTY] == INT16_MIN);
    assert(!r.axes[SC_GAMEPAD_AXIS_RIGHTX]);
    sc_keyboard_gamepad_handle_mouse_motion(&kg, 32, 0, 112);
    assert(tick(116));
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTY] == INT16_MIN);
    assert(!r.axes[SC_GAMEPAD_AXIS_RIGHTX]);
    now_ms = 118;
    release(SDL_SCANCODE_I);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHTX] == INT16_MAX);
    assert(!tick(200));
    assert_neutral();

    // Sensitivity scales it, and the left stick can be the mouse's
    setup("mouse_stick=left,mouse_sensitivity=50");
    sc_keyboard_gamepad_handle_mouse_motion(&kg, 32, 0, 0);
    assert(tick(8));
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == 16383);
    assert(!r.axes[SC_GAMEPAD_AXIS_RIGHTX]);
    setup("mouse_stick=sideways,mouse_sensitivity=0");
    assert(kg.mouse_stick == SC_KEYBOARD_GAMEPAD_MOUSE_STICK_OFF);
    assert(kg.mouse_sensitivity == 100);
}

static void test_spec(void) {
    // A key given to a second control stays with the first; unknown controls
    // and keys are skipped
    setup("a=W,left_stick_up=W/Up,nope=K,b=NoSuchKey,y");
    assert(kg.key_count == 2);
    press(SDL_SCANCODE_W);
    assert(r.buttons == UINT32_C(1) << SC_GAMEPAD_BUTTON_SOUTH);
    press(SDL_SCANCODE_UP);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTY] == INT16_MIN);
    assert(!key_event(SDL_SCANCODE_K, true, SDL_KMOD_NONE, false));

    // "_" stands for a space in a key name
    setup("start=Keypad_Enter");
    press(SDL_SCANCODE_KP_ENTER);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_START));

    // Settings: good values are taken, bad ones reported and left
    setup("ramp_ms=250,walk_percent=75,socd=neutral,socd_right_stick=last");
    assert(kg.ramp_ms == 250);
    assert(kg.walk_percent == 75);
    assert(kg.socd[0] == SC_KEYBOARD_GAMEPAD_SOCD_NEUTRAL);
    assert(kg.socd[1] == SC_KEYBOARD_GAMEPAD_SOCD_NEUTRAL);
    assert(kg.socd[2] == SC_KEYBOARD_GAMEPAD_SOCD_LAST);
    assert(!kg.key_count);
    setup("ramp_ms=abc,walk_percent=0,socd=sometimes,ramp_ms=9999");
    assert(!kg.ramp_ms);
    assert(kg.walk_percent == 50);
    assert(kg.socd[0] == SC_KEYBOARD_GAMEPAD_SOCD_LAST);
}

// Holding a trigger (X accelerates in a racing game) leaves the D-pad and the
// sticks free, through their key repeats and the trigger's
static void test_trigger_held_with_directions(void) {
    setup(NULL);

    press(SDL_SCANCODE_X);
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHT_TRIGGER] == INT16_MAX);

    press(SDL_SCANCODE_LEFT);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));
    // The arrow repeats now, as the last key pressed
    assert(key_event(SDL_SCANCODE_LEFT, true, SDL_KMOD_NONE, true));
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));
    release(SDL_SCANCODE_LEFT);
    assert(!button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));

    press(SDL_SCANCODE_RIGHT);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_RIGHT));
    release(SDL_SCANCODE_RIGHT);

    press(SDL_SCANCODE_A);
    assert(r.axes[SC_GAMEPAD_AXIS_LEFTX] == INT16_MIN);
    release(SDL_SCANCODE_A);
    assert(!r.axes[SC_GAMEPAD_AXIS_LEFTX]);

    // Still accelerating, and a repeat of X changes nothing
    assert(r.axes[SC_GAMEPAD_AXIS_RIGHT_TRIGGER] == INT16_MAX);
    assert(key_event(SDL_SCANCODE_X, true, SDL_KMOD_NONE, true));
    press(SDL_SCANCODE_LEFT);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));
    release(SDL_SCANCODE_X);
    assert(!r.axes[SC_GAMEPAD_AXIS_RIGHT_TRIGGER]);
    assert(button_down(&r, SC_GAMEPAD_BUTTON_DPAD_LEFT));
    release(SDL_SCANCODE_LEFT);
    assert_neutral();
}

int main(int argc, char *argv[]) {
    (void) argc;
    (void) argv;

    test_stick_and_dpad_apart();
    test_stick_diagonal_round_gate();
    test_stick_in_one_report();
    test_last_direction_counts();
    test_socd_neutral();
    test_ramp();
    test_walk();
    test_control_held_by_any_key();
    test_default_buttons();
    test_trigger_held_with_directions();
    test_modifiers_and_repeats();
    test_release_all();
    test_mouse_buttons_and_wheel();
    test_mouse_stick();
    test_spec();
    return 0;
}
