#include "common.h"

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ika/keyboard_touch.h"
#include "input_events.h"

// A sink that keeps the fingers on a display (1000x500 unless a test says
// otherwise), and checks that a finger goes down only when up, moves or goes
// up only when down, and that no more than ten touch at once
#define MAX_FINGERS 64

struct finger {
    uint64_t id;
    bool down;
    struct sc_point at;
};

static struct finger fingers[MAX_FINGERS];
static size_t finger_count;
static unsigned events;
static struct sc_size display = {1000, 500};
// The times no aim finger was down right after one lifted
static unsigned aim_gaps;

#define TAP(i) (SC_KEYBOARD_TOUCH_POINTER_ID + (i))
#define JOY SC_KEYBOARD_TOUCH_JOYSTICK_POINTER_ID
#define AIM SC_KEYBOARD_TOUCH_AIM_POINTER_ID

static struct finger *
finger(uint64_t id) {
    for (size_t i = 0; i < finger_count; ++i) {
        if (fingers[i].id == id) {
            return &fingers[i];
        }
    }
    assert(finger_count < MAX_FINGERS);
    fingers[finger_count] = (struct finger) {.id = id};
    return &fingers[finger_count++];
}

static unsigned
down_count(void) {
    unsigned n = 0;
    for (size_t i = 0; i < finger_count; ++i) {
        n += fingers[i].down;
    }
    return n;
}

static struct sc_size
sink_get_size(void *userdata) {
    (void) userdata;
    return display;
}

static void
sink_touch(void *userdata, enum android_motionevent_action action,
           uint64_t pointer_id, struct sc_point point) {
    (void) userdata;
    struct finger *f = finger(pointer_id);
    assert(point.x >= 0 && point.x < display.width);
    assert(point.y >= 0 && point.y < display.height);
    if (action == AMOTION_EVENT_ACTION_DOWN) {
        assert(!f->down);
        f->down = true;
        assert(down_count() <= SC_KEYBOARD_TOUCH_MAX_FINGERS);
    } else {
        assert(f->down);
        assert(action == AMOTION_EVENT_ACTION_MOVE
               || action == AMOTION_EVENT_ACTION_UP);
        f->down = action != AMOTION_EVENT_ACTION_UP;
    }
    f->at = point;
    events++;
    if (action == AMOTION_EVENT_ACTION_UP
            && (pointer_id == AIM || pointer_id == AIM + 1)
            && !finger(AIM)->down && !finger(AIM + 1)->down) {
        aim_gaps++;
    }
}

static const struct sc_keyboard_touch_sink sink = {
    .get_size = sink_get_size,
    .touch = sink_touch,
};

// A timer that only says it was armed; the tests tick by hand
static bool timer_armed;

static void
timer_arm(void *userdata) {
    (void) userdata;
    timer_armed = true;
}

static const struct sc_keyboard_gamepad_timer timer = {
    .arm = timer_arm,
};

static struct sc_keyboard_touch kt;
static uint64_t now_ms;

static void
setup(const char *spec) {
    memset(fingers, 0, sizeof(fingers));
    finger_count = 0;
    events = 0;
    aim_gaps = 0;
    display = (struct sc_size) {1000, 500};
    timer_armed = false;
    now_ms = 1000;
    sc_keyboard_touch_init(&kt, spec);
    kt.sink = &sink;
    // Ika's MOD
    kt.shortcut_mods = SDL_KMOD_LALT | SDL_KMOD_LGUI;
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
    return sc_keyboard_touch_handle_key(&kt, &event);
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
at(uint64_t id, int32_t x, int32_t y) {
    struct finger *f = finger(id);
    return f->down && f->at.x == x && f->at.y == y;
}

static void
test_parse(void) {
    setup("Space=0.5:0.8,F/Mouse_Right=0.9:0.6,joystick=0.15:0.75:0.1,"
          "aim=0.6:0.5:0.2,aim_sensitivity=50,joystick_walk=Left_Ctrl,"
          "joystick_sprint=Left_Shift,joystick_ramp_ms=0,aspect=1.777,"
          "Q=0.8:0.7:cast:0.12,cast_center=0.4:0.6");
    assert(kt.tap_count == 3);
    // Space, F, Mouse_Right, Q, Left Ctrl, Left Shift, and W, S, A and D
    assert(kt.key_count == 10);
    assert(kt.has_joystick && kt.has_aim);
    assert(kt.aim_sensitivity == 50);
    assert(kt.joystick_ramp_ms == 0);
    assert(fabsf(kt.aspect - 1.777f) < 0.0001f);
    assert(kt.kinds[2] == SC_KEYBOARD_TOUCH_CAST && kt.taps[2].r == 0.12f);
    assert(kt.cast_center.x == 0.4f && kt.cast_center.y == 0.6f);
    assert(sc_keyboard_touch_takes_mouse(&kt));

    // Bad values, a key used twice, an unknown key, the wheel
    setup("Space=1.5:0.2,joystick=0.1:0.1,aim_sensitivity=0,Foo=0.1:0.1,"
          "B=0.1:0.2:0.3,C=0.2:0.2,C=0.3:0.3,Wheel_Up=0.5:0.5,D=,=0.5:0.5,"
          "E=0.1:0.1:cast,G=0.1:0.1:cast:0,aspect=0,"
          "joystick_sprint_percent=50");
    assert(kt.tap_count == 1);
    assert(kt.key_count == 1);
    assert(!kt.has_joystick);
    assert(!kt.has_aim);
    assert(kt.aim_sensitivity == 100);
    assert(kt.aspect == 0);
    assert(kt.joystick_sprint_percent == 200);
    assert(!sc_keyboard_touch_takes_mouse(&kt));

    // The aspect as a fraction, with or without blanks around the slash
    setup("aspect=16/9");
    assert(fabsf(kt.aspect - 16.f / 9) < 0.0001f);
    setup("aspect=4:/:3");
    assert(fabsf(kt.aspect - 4.f / 3) < 0.0001f);
    setup("aspect=16/0");
    assert(kt.aspect == 0);
}

static void
test_tap(void) {
    setup("Space=0.5:0.8");
    press(SDL_SCANCODE_SPACE);
    assert(at(TAP(0), 500, 400));
    // A repeat keeps it down, with no event
    unsigned before = events;
    assert(key_event(SDL_SCANCODE_SPACE, true, SDL_KMOD_NONE, true));
    assert(events == before);
    release(SDL_SCANCODE_SPACE);
    assert(!finger(TAP(0))->down);

    // Not a touch key
    assert(!key_event(SDL_SCANCODE_Q, true, SDL_KMOD_NONE, false));
    // A shortcut (MOD+key) is not a touch, nor is its release
    assert(!key_event(SDL_SCANCODE_SPACE, true, SDL_KMOD_LALT, false));
    assert(!key_event(SDL_SCANCODE_SPACE, false, SDL_KMOD_LALT, false));
    assert(!down_count());

    // Other modifiers held, as Ctrl to crouch, do not stop a touch key
    assert(key_event(SDL_SCANCODE_SPACE, true, SDL_KMOD_LCTRL, false));
    assert(down_count() == 1);

    // A held key is released whatever modifier is down by then
    assert(key_event(SDL_SCANCODE_SPACE, false, SDL_KMOD_LGUI, false));
    assert(!down_count());

    // Ctrl itself can touch
    setup("Left_Ctrl=0.5:0.5");
    assert(key_event(SDL_SCANCODE_LCTRL, true, SDL_KMOD_LCTRL, false));
    assert(down_count() == 1);
    assert(key_event(SDL_SCANCODE_LCTRL, false, SDL_KMOD_NONE, false));
    assert(!down_count());
}

static void
test_tap_shared_by_keys(void) {
    setup("F/Mouse_Right=0.9:0.6,G=0.1:0.1");
    press(SDL_SCANCODE_F);
    assert(sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_RIGHT,
                                                 true, true));
    assert(down_count() == 1);
    release(SDL_SCANCODE_F);
    assert(down_count() == 1);
    // Two fingers at once
    press(SDL_SCANCODE_G);
    assert(down_count() == 2);
    assert(sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_RIGHT,
                                                 false, true));
    assert(down_count() == 1);
    release(SDL_SCANCODE_G);
    assert(!down_count());

    // Captured, an unmapped button is dropped, its release is not the touch
    // keys'
    assert(sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_LEFT,
                                                 true, true));
    assert(!sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_LEFT,
                                                  false, true));
    assert(!down_count());
}

static void
test_free_mouse_buttons(void) {
    setup("Mouse_Right=0.5:0.5,Mouse_Left=0.2:0.2");
    // Free, the left button stays the mouse's own finger, and an unmapped
    // button is the mouse's too
    assert(!sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_LEFT,
                                                  true, false));
    assert(!sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_MIDDLE,
                                                  true, false));
    assert(!down_count());
    // ... and the right one touches its point
    assert(sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_RIGHT,
                                                 true, false));
    assert(at(TAP(0), 500, 250));
    assert(sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_RIGHT,
                                                 false, false));
    assert(!down_count());
}

static void
test_joystick(void) {
    setup("joystick=0.15:0.75:0.1,joystick_ramp_ms=0");
    // Center (150, 375), radius 50
    press(SDL_SCANCODE_W);
    assert(at(JOY, 150, 325));
    press(SDL_SCANCODE_D);
    // On a diagonal, as far from the center as on an axis
    assert(at(JOY, 185, 340));
    // Of two opposite directions, the last pressed counts
    press(SDL_SCANCODE_S);
    assert(at(JOY, 185, 410));
    release(SDL_SCANCODE_S);
    assert(at(JOY, 185, 340));
    release(SDL_SCANCODE_D);
    assert(at(JOY, 150, 325));
    release(SDL_SCANCODE_W);
    assert(!finger(JOY)->down);
}

static void
test_joystick_ramp_walk_sprint(void) {
    setup("joystick=0.15:0.75:0.1,joystick_walk=Left_Ctrl,"
          "joystick_sprint=Left_Shift");
    kt.timer = &timer;
    assert(kt.joystick_ramp_ms == 60);
    press(SDL_SCANCODE_W);
    // From the center, a quarter of the way at once, then over 60 ms
    assert(timer_armed);
    assert(at(JOY, 150, 363));
    assert(sc_keyboard_touch_tick(&kt, now_ms + 30));
    assert(at(JOY, 150, 350));
    assert(!sc_keyboard_touch_tick(&kt, now_ms + 60));
    assert(at(JOY, 150, 325));
    now_ms += 100;

    // A direction added later goes there at once
    press(SDL_SCANCODE_D);
    assert(at(JOY, 185, 340));
    // Walking, half as far; sprinting, twice as far, sprint winning
    press(SDL_SCANCODE_LCTRL);
    assert(at(JOY, 168, 357));
    press(SDL_SCANCODE_LSHIFT);
    assert(at(JOY, 221, 304));
    release(SDL_SCANCODE_LSHIFT);
    release(SDL_SCANCODE_LCTRL);
    assert(at(JOY, 185, 340));
    release(SDL_SCANCODE_D);
    release(SDL_SCANCODE_W);
    assert(!finger(JOY)->down);

    // Walk alone touches nothing
    press(SDL_SCANCODE_LCTRL);
    assert(!down_count());
    release(SDL_SCANCODE_LCTRL);
}

static void
test_aim(void) {
    setup("aim=0.6:0.5:0.2,aim_sensitivity=100");
    // Center (600, 250), radius 100
    sc_keyboard_touch_handle_mouse_motion(&kt, 10, 0);
    assert(at(AIM, 610, 250));
    sc_keyboard_touch_handle_mouse_motion(&kt, 80, 0);
    assert(at(AIM, 690, 250));
    // Past the radius, the other finger touches the center before the first
    // lifts at the edge, and takes the rest of the motion
    sc_keyboard_touch_handle_mouse_motion(&kt, 20, 5);
    assert(!finger(AIM)->down);
    assert(finger(AIM)->at.x == 700 && finger(AIM)->at.y == 252);
    assert(at(AIM + 1, 610, 253));
    assert(!aim_gaps);

    // A flick of many radii: always a finger down, ending inside the circle
    sc_keyboard_touch_handle_mouse_motion(&kt, 1000, -300);
    assert(!aim_gaps);
    assert(down_count() == 1);
    struct finger *f = finger(AIM)->down ? finger(AIM) : finger(AIM + 1);
    float dx = f->at.x - 600;
    float dy = f->at.y - 250;
    assert(dx * dx + dy * dy <= 101 * 101);

    sc_keyboard_touch_release_mouse(&kt);
    assert(!down_count());
    assert(aim_gaps == 1);

    // At sensitivity 50, half the motion
    setup("aim=0.6:0.5:0.2,aim_sensitivity=50");
    sc_keyboard_touch_handle_mouse_motion(&kt, 10, -20);
    assert(at(AIM, 605, 240));
}

static void
test_aspect(void) {
    // Placed at 16:9, played at 2:1: the right third keeps its distance
    // from the right edge, the left third from the left one, the middle from
    // the center, in display heights; heights scale
    setup("aspect=1.777,Space=0.9:0.8,F=0.1:0.2,G=0.5:0.5");
    press(SDL_SCANCODE_SPACE);
    press(SDL_SCANCODE_F);
    press(SDL_SCANCODE_G);
    assert(at(TAP(0), 911, 400));
    assert(at(TAP(1), 89, 100));
    assert(at(TAP(2), 500, 250));
    sc_keyboard_touch_release_all(&kt);

    // At the same aspect ratio, or with none known, the fractions as given
    setup("aspect=2,Space=0.9:0.8");
    press(SDL_SCANCODE_SPACE);
    assert(at(TAP(0), 900, 400));
    setup("Space=0.9:0.8");
    press(SDL_SCANCODE_SPACE);
    assert(at(TAP(0), 900, 400));

    // Portrait: anchored to the top, middle or bottom, in display widths
    setup("aspect=0.5,Space=0.5:0.9");
    display = (struct sc_size) {500, 800};
    press(SDL_SCANCODE_SPACE);
    // 0.9 of 2 widths is 1.8, 0.2 from the bottom: 800 - 100
    assert(at(TAP(0), 250, 700));

    // The editor's rebase moves the points to where they are shown
    setup("aspect=1.777,Space=0.9:0.8");
    sc_keyboard_touch_rebase(&kt, display);
    assert(kt.aspect == 2.0f);
    assert(fabsf(kt.taps[0].x - 0.911f) < 0.001f);
    press(SDL_SCANCODE_SPACE);
    assert(at(TAP(0), 911, 400));
}

static void
test_cast(void) {
    setup("Q=0.8:0.7:cast:0.1");
    // No pointer known: a plain tap
    press(SDL_SCANCODE_Q);
    assert(at(TAP(0), 800, 350));
    release(SDL_SCANCODE_Q);

    // The pointer half the display's height right of the character (the
    // center): the whole reach (50) that way
    sc_keyboard_touch_set_cursor(&kt, true, 750, 250);
    press(SDL_SCANCODE_Q);
    assert(at(TAP(0), 850, 350));
    // It follows the pointer while held
    sc_keyboard_touch_set_cursor(&kt, true, 500, 375);
    assert(at(TAP(0), 800, 375));
    // Far away, no farther than its reach
    sc_keyboard_touch_set_cursor(&kt, true, 0, 250);
    assert(at(TAP(0), 750, 350));
    release(SDL_SCANCODE_Q);
    assert(!down_count());
    assert(finger(TAP(0))->at.x == 750);
}

static void
test_ten_fingers(void) {
    setup("A=0.1:0.1,B=0.2:0.1,C=0.3:0.1,D=0.4:0.1,E=0.5:0.1,F=0.6:0.1,"
          "G=0.7:0.1,H=0.8:0.1,I=0.9:0.1,J=0.1:0.9,K=0.2:0.9");
    SDL_Scancode keys[] = {
        SDL_SCANCODE_A, SDL_SCANCODE_B, SDL_SCANCODE_C, SDL_SCANCODE_D,
        SDL_SCANCODE_E, SDL_SCANCODE_F, SDL_SCANCODE_G, SDL_SCANCODE_H,
        SDL_SCANCODE_I, SDL_SCANCODE_J, SDL_SCANCODE_K,
    };
    for (size_t i = 0; i < ARRAY_LEN(keys); ++i) {
        press(keys[i]);
    }
    // The eleventh touches nothing, and its release sends nothing
    assert(down_count() == 10);
    assert(!finger(TAP(10))->down);
    unsigned before = events;
    release(SDL_SCANCODE_K);
    assert(events == before);
    // A finger freed, a key touches again
    release(SDL_SCANCODE_A);
    press(SDL_SCANCODE_K);
    assert(finger(TAP(10))->down);
    sc_keyboard_touch_release_all(&kt);
    assert(!down_count());
}

static void
test_release_all(void) {
    setup("Space=0.5:0.8,Mouse_Left=0.7:0.7,joystick=0.15:0.75:0.1,"
          "aim=0.6:0.5:0.2");
    press(SDL_SCANCODE_SPACE);
    press(SDL_SCANCODE_A);
    assert(sc_keyboard_touch_handle_mouse_button(&kt, SC_MOUSE_BUTTON_LEFT,
                                                 true, true));
    sc_keyboard_touch_handle_mouse_motion(&kt, 5, 5);
    assert(down_count() == 4);

    // The pointer let go: the mouse's fingers lift, the keys' stay
    sc_keyboard_touch_release_mouse(&kt);
    assert(down_count() == 2);
    sc_keyboard_touch_release_all(&kt);
    assert(!down_count());
    // Their releases are no longer the touch keys'
    assert(!key_event(SDL_SCANCODE_SPACE, false, SDL_KMOD_NONE, false));
}

static void
test_edit(void) {
    setup("Space=0.5:0.8,F=0.9:0.6");
    int t = sc_keyboard_touch_add_tap(&kt, 0.2f, 0.3f);
    assert(t == 2 && kt.tap_count == 3);

    // Moving F to the new tap removes F's old tap, and the new one's index
    // follows
    t = sc_keyboard_touch_bind(&kt, SC_KEYBOARD_GAMEPAD_INPUT_KEY,
                               SDL_SCANCODE_F, t);
    assert(t == 1 && kt.tap_count == 2);
    assert(kt.taps[1].x == 0.2f);
    press(SDL_SCANCODE_F);
    assert(finger(TAP(1))->at.x == 200);
    release(SDL_SCANCODE_F);

    // A second key on the tap, then taken off again
    sc_keyboard_touch_bind(&kt, SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON,
                           SC_MOUSE_BUTTON_X1, 1);
    assert(kt.key_count == 3);
    sc_keyboard_touch_bind(&kt, SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON,
                           SC_MOUSE_BUTTON_X1, 1);
    assert(kt.key_count == 2);

    // A tap left with no key stays until pruned
    sc_keyboard_touch_bind(&kt, SC_KEYBOARD_GAMEPAD_INPUT_KEY,
                           SDL_SCANCODE_SPACE, 0);
    assert(kt.tap_count == 2 && kt.key_count == 1);
    sc_keyboard_touch_prune(&kt);
    assert(kt.tap_count == 1 && kt.taps[0].x == 0.2f);

    // The joystick takes its default keys where free
    sc_keyboard_touch_bind(&kt, SC_KEYBOARD_GAMEPAD_INPUT_KEY,
                           SDL_SCANCODE_W, 0);
    sc_keyboard_touch_set_joystick(&kt, true, 0.15f, 0.75f, 0.1f);
    assert(kt.key_count == 5); // F and W on the tap, S, A, D
    sc_keyboard_touch_bind(&kt, SC_KEYBOARD_GAMEPAD_INPUT_KEY,
                           SDL_SCANCODE_UP, SC_KEYBOARD_TOUCH_JOYSTICK_UP);
    sc_keyboard_touch_bind(&kt, SC_KEYBOARD_GAMEPAD_INPUT_KEY,
                           SDL_SCANCODE_LCTRL, SC_KEYBOARD_TOUCH_JOYSTICK_WALK);
    press(SDL_SCANCODE_UP);
    assert(finger(JOY)->down);
    release(SDL_SCANCODE_UP);
    sc_keyboard_touch_set_joystick(&kt, false, 0, 0, 0);
    assert(kt.key_count == 2 && !kt.has_joystick);

    sc_keyboard_touch_remove_tap(&kt, 0);
    assert(!kt.tap_count && !kt.key_count);
}

static void
test_file(void) {
    char path[] = "/tmp/test_keyboard_touch_XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);

    setup("Space/Left_Shift=0.5:0.8,Mouse_Right=0.9:0.625,"
          "joystick=0.15:0.75:0.1,joystick_up=Up,joystick_walk=Left_Ctrl,"
          "joystick_ramp_ms=40,joystick_sprint_percent=250,"
          "aim=0.6:0.5:0.2,aim_sensitivity=70,aspect=1.778,"
          "Q=0.8:0.7:cast:0.12,cast_center=0.45:0.55");
    assert(sc_keyboard_touch_save(&kt, path));

    struct sc_keyboard_touch saved = kt;
    sc_keyboard_touch_init_file(&kt, path);
    assert(kt.tap_count == saved.tap_count);
    assert(kt.key_count == saved.key_count);
    // The same keys for the same targets, in whatever order
    for (size_t i = 0; i < saved.key_count; ++i) {
        bool found = false;
        for (size_t j = 0; j < kt.key_count; ++j) {
            found |= kt.keys[j].input == saved.keys[i].input
                  && kt.keys[j].code == saved.keys[i].code
                  && kt.keys[j].target == saved.keys[i].target;
        }
        assert(found);
    }
    for (size_t i = 0; i < kt.tap_count; ++i) {
        assert(kt.taps[i].x == saved.taps[i].x);
        assert(kt.taps[i].y == saved.taps[i].y);
        assert(kt.taps[i].r == saved.taps[i].r);
        assert(kt.kinds[i] == saved.kinds[i]);
    }
    assert(kt.has_joystick && kt.joystick.r == saved.joystick.r);
    assert(kt.joystick_ramp_ms == 40 && kt.joystick_sprint_percent == 250);
    assert(kt.has_aim && kt.aim_sensitivity == 70);
    assert(fabsf(kt.aspect - 1.778f) < 0.0001f);
    assert(kt.cast_center.x == 0.45f && kt.cast_center.y == 0.55f);

    // A hand-written file: blanks, comments, other sections, commas
    FILE *f = fopen(path, "w");
    assert(f);
    fputs("# comment\n[other]\nSpace = 0.1 0.1\n\n[TOUCH]\n"
          "  Left_Shift   F = 0.25, 0.5  \n"
          "joystick=0.2 0.7 0.1\r\n"
          "; comment\n"
          "joystick_up = I/Up\n"
          "R = 0.7 0.7 cast 0.1\n", f);
    fclose(f);
    sc_keyboard_touch_init_file(&kt, path);
    assert(kt.tap_count == 2);
    assert(kt.taps[0].x == 0.25f && kt.taps[0].y == 0.5f);
    assert(kt.keys[0].code == SDL_SCANCODE_LSHIFT);
    assert(kt.keys[1].code == SDL_SCANCODE_F && kt.keys[1].target == 0);
    assert(kt.kinds[1] == SC_KEYBOARD_TOUCH_CAST);
    assert(kt.has_joystick && kt.joystick.x == 0.2f);
    // Left Shift, F, I and Up, R, S, A, D
    assert(kt.key_count == 8);

    remove(path);
    // No file: no keys
    sc_keyboard_touch_init_file(&kt, path);
    assert(!kt.tap_count && !kt.key_count);

    char name[32];
    struct sc_keyboard_touch_key key = {
        .input = SC_KEYBOARD_GAMEPAD_INPUT_KEY,
        .code = SDL_SCANCODE_RSHIFT,
    };
    sc_keyboard_touch_key_name(&key, false, name, sizeof(name));
    assert(!strcmp(name, "Right_Shift"));
    sc_keyboard_touch_key_name(&key, true, name, sizeof(name));
    assert(!strcmp(name, "Right Shift"));
    key.input = SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON;
    key.code = SC_MOUSE_BUTTON_MIDDLE;
    sc_keyboard_touch_key_name(&key, true, name, sizeof(name));
    assert(!strcmp(name, "Mouse Middle"));
}

int main(int argc, char *argv[]) {
    (void) argc;
    (void) argv;

    test_parse();
    test_tap();
    test_tap_shared_by_keys();
    test_free_mouse_buttons();
    test_joystick();
    test_joystick_ramp_walk_sprint();
    test_aim();
    test_aspect();
    test_cast();
    test_ten_fingers();
    test_release_all();
    test_edit();
    test_file();
    return 0;
}
