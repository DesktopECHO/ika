#include "keyboard_gamepad.h"

#include <assert.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "input_events.h"
#include "util/log.h"

#define SC_KEYBOARD_GAMEPAD_DEFAULT_SPEC \
    "left_stick_up=W,left_stick_down=S,left_stick_left=A," \
    "left_stick_right=D,dpad_up=Up,dpad_down=Down,dpad_left=Left," \
    "dpad_right=Right,right_stick_up=I,right_stick_down=K," \
    "right_stick_left=J,right_stick_right=L,a=Space,b=Escape,x=C,y=V," \
    "start=Return/Keypad_Enter,back=Backspace,left_shoulder=Q," \
    "right_shoulder=E,left_stick=Left_Shift,right_stick=F," \
    "left_trigger=Z,right_trigger=X,walk=Tab"

#define KG_DEFAULT_WALK_PERCENT 50

// A stick pushed on a diagonal, on each axis: INT16_MAX / sqrt(2), so that it
// is as far from its center as on an axis, as in the round gate of a stick
#define KG_STICK_DIAGONAL 23170

// A ramp's first step, sent as the key goes down: the deflection of one tick
// of the owner's timer, so that the stick moves at once rather than at the
// first tick
#define KG_FIRST_STEP_MS 8

// The mouse's stick: full deflection at this many pixels per 8 ms at
// mouse_sensitivity=100, and back to the center when no motion came for
// KG_MOUSE_HOLD_MS (a mouse reports every 8 ms at most, some every 16)
#define KG_MOUSE_FULL_PX 32
#define KG_MOUSE_HOLD_MS 24
#define KG_DEFAULT_MOUSE_SENSITIVITY 100

// A wheel notch presses its control for this long
#define KG_WHEEL_PULSE_MS 40

enum kg_pad {
    KG_DPAD,
    KG_LEFT_STICK,
    KG_RIGHT_STICK,
};

static_assert(KG_RIGHT_STICK + 1 == SC_KEYBOARD_GAMEPAD_PAD_COUNT,
              "one direction state per pad");

enum kg_kind {
    KG_KIND_BUTTON,
    KG_KIND_TRIGGER,
    KG_KIND_DIRECTION,
    KG_KIND_WALK,
};

struct sc_keyboard_gamepad_control {
    const char *name;
    enum kg_kind kind;
    enum sc_gamepad_button button; // KG_KIND_BUTTON
    enum sc_gamepad_axis axis; // KG_KIND_TRIGGER
    // KG_KIND_DIRECTION: the pad, its axis, and -1 (left or up) or 1
    enum kg_pad pad;
    bool vertical;
    int8_t sign;
};

#define KG_BUTTON(NAME, BUTTON) \
    {.name = NAME, .kind = KG_KIND_BUTTON, .button = BUTTON}
#define KG_TRIGGER(NAME, AXIS) \
    {.name = NAME, .kind = KG_KIND_TRIGGER, .axis = AXIS}
#define KG_DIRECTION(NAME, PAD, VERTICAL, SIGN) \
    {.name = NAME, .kind = KG_KIND_DIRECTION, .pad = PAD, \
     .vertical = VERTICAL, .sign = SIGN}

static const struct sc_keyboard_gamepad_control kg_controls[] = {
    KG_DIRECTION("left_stick_up", KG_LEFT_STICK, true, -1),
    KG_DIRECTION("left_stick_down", KG_LEFT_STICK, true, 1),
    KG_DIRECTION("left_stick_left", KG_LEFT_STICK, false, -1),
    KG_DIRECTION("left_stick_right", KG_LEFT_STICK, false, 1),
    KG_DIRECTION("dpad_up", KG_DPAD, true, -1),
    KG_DIRECTION("dpad_down", KG_DPAD, true, 1),
    KG_DIRECTION("dpad_left", KG_DPAD, false, -1),
    KG_DIRECTION("dpad_right", KG_DPAD, false, 1),
    KG_DIRECTION("right_stick_up", KG_RIGHT_STICK, true, -1),
    KG_DIRECTION("right_stick_down", KG_RIGHT_STICK, true, 1),
    KG_DIRECTION("right_stick_left", KG_RIGHT_STICK, false, -1),
    KG_DIRECTION("right_stick_right", KG_RIGHT_STICK, false, 1),
    KG_BUTTON("a", SC_GAMEPAD_BUTTON_SOUTH),
    KG_BUTTON("b", SC_GAMEPAD_BUTTON_EAST),
    KG_BUTTON("x", SC_GAMEPAD_BUTTON_WEST),
    KG_BUTTON("y", SC_GAMEPAD_BUTTON_NORTH),
    KG_BUTTON("start", SC_GAMEPAD_BUTTON_START),
    KG_BUTTON("back", SC_GAMEPAD_BUTTON_BACK),
    KG_BUTTON("guide", SC_GAMEPAD_BUTTON_GUIDE),
    KG_BUTTON("left_shoulder", SC_GAMEPAD_BUTTON_LEFT_SHOULDER),
    KG_BUTTON("right_shoulder", SC_GAMEPAD_BUTTON_RIGHT_SHOULDER),
    KG_BUTTON("left_stick", SC_GAMEPAD_BUTTON_LEFT_STICK),
    KG_BUTTON("right_stick", SC_GAMEPAD_BUTTON_RIGHT_STICK),
    KG_TRIGGER("left_trigger", SC_GAMEPAD_AXIS_LEFT_TRIGGER),
    KG_TRIGGER("right_trigger", SC_GAMEPAD_AXIS_RIGHT_TRIGGER),
    {.name = "walk", .kind = KG_KIND_WALK},
};

static const struct sc_keyboard_gamepad_control *
kg_find_control(const char *name, size_t len) {
    for (size_t i = 0; i < ARRAY_LEN(kg_controls); ++i) {
        const struct sc_keyboard_gamepad_control *c = &kg_controls[i];
        if (strlen(c->name) == len && !strncmp(c->name, name, len)) {
            return c;
        }
    }
    return NULL;
}

static const struct {
    const char *name;
    enum sc_keyboard_gamepad_input input;
    uint32_t code;
} kg_mouse_inputs[] = {
    {"mouse left", SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON, SC_MOUSE_BUTTON_LEFT},
    {"mouse right", SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON,
     SC_MOUSE_BUTTON_RIGHT},
    {"mouse middle", SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON,
     SC_MOUSE_BUTTON_MIDDLE},
    {"mouse x1", SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON, SC_MOUSE_BUTTON_X1},
    {"mouse x2", SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON, SC_MOUSE_BUTTON_X2},
    {"wheel up", SC_KEYBOARD_GAMEPAD_INPUT_WHEEL, SC_KEYBOARD_GAMEPAD_WHEEL_UP},
    {"wheel down", SC_KEYBOARD_GAMEPAD_INPUT_WHEEL,
     SC_KEYBOARD_GAMEPAD_WHEEL_DOWN},
    {"wheel left", SC_KEYBOARD_GAMEPAD_INPUT_WHEEL,
     SC_KEYBOARD_GAMEPAD_WHEEL_LEFT},
    {"wheel right", SC_KEYBOARD_GAMEPAD_INPUT_WHEEL,
     SC_KEYBOARD_GAMEPAD_WHEEL_RIGHT},
};

// The input "name" (len bytes) stands for, with "_" standing for a space: a
// mouse button or wheel direction of kg_mouse_inputs, else an SDL key name
static bool
kg_parse_input(const char *name, size_t len,
               enum sc_keyboard_gamepad_input *input, uint32_t *code) {
    char buf[32];
    if (!len || len >= sizeof(buf)) {
        return false;
    }
    for (size_t i = 0; i < len; ++i) {
        buf[i] = name[i] == '_' ? ' ' : name[i];
    }
    buf[len] = '\0';
    for (size_t i = 0; i < ARRAY_LEN(kg_mouse_inputs); ++i) {
        if (!SDL_strcasecmp(buf, kg_mouse_inputs[i].name)) {
            *input = kg_mouse_inputs[i].input;
            *code = kg_mouse_inputs[i].code;
            return true;
        }
    }
    SDL_Scancode scancode = SDL_GetScancodeFromName(buf);
    if (scancode == SDL_SCANCODE_UNKNOWN) {
        return false;
    }
    *input = SC_KEYBOARD_GAMEPAD_INPUT_KEY;
    *code = scancode;
    return true;
}

static void
kg_add_key(struct sc_keyboard_gamepad *kg,
           const struct sc_keyboard_gamepad_control *control,
           const char *name, size_t len) {
    enum sc_keyboard_gamepad_input input;
    uint32_t code;
    if (!kg_parse_input(name, len, &input, &code)) {
        LOGW("Keyboard gamepad: unknown key '%.*s' for %s; ignored",
             (int) len, name, control->name);
        return;
    }
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].input == input && kg->keys[i].code == code) {
            LOGW("Keyboard gamepad: key '%.*s' already used; ignored for %s",
                 (int) len, name, control->name);
            return;
        }
    }
    if (kg->key_count == SC_KEYBOARD_GAMEPAD_MAX_KEYS) {
        LOGW("Keyboard gamepad: too many keys; '%.*s' ignored", (int) len,
             name);
        return;
    }
    kg->keys[kg->key_count++] = (struct sc_keyboard_gamepad_key) {
        .input = input,
        .code = code,
        .control = control,
        .pressed = 0,
        .release_ms = 0,
    };
}

static bool
kg_parse_number(const char *value, size_t len, uint32_t min, uint32_t max,
                uint32_t *out) {
    uint32_t n = 0;
    if (!len || len > 9) {
        return false;
    }
    for (size_t i = 0; i < len; ++i) {
        if (value[i] < '0' || value[i] > '9') {
            return false;
        }
        n = n * 10 + (uint32_t) (value[i] - '0');
    }
    if (n < min || n > max) {
        return false;
    }
    *out = n;
    return true;
}

static bool
kg_parse_socd(const char *value, size_t len,
              enum sc_keyboard_gamepad_socd *out) {
    if (len == 4 && !strncmp(value, "last", 4)) {
        *out = SC_KEYBOARD_GAMEPAD_SOCD_LAST;
        return true;
    }
    if (len == 7 && !strncmp(value, "neutral", 7)) {
        *out = SC_KEYBOARD_GAMEPAD_SOCD_NEUTRAL;
        return true;
    }
    return false;
}

// A setting of the spec ("ramp_ms=100"): true if name is one, whether or
// not its value was good (a bad value is reported and left as it was)
static bool
kg_parse_setting(struct sc_keyboard_gamepad *kg, const char *name,
                 size_t name_len, const char *value, size_t value_len) {
    uint32_t n;
    enum sc_keyboard_gamepad_socd socd;

    if (name_len == 7 && !strncmp(name, "ramp_ms", 7)) {
        if (kg_parse_number(value, value_len, 0,
                            SC_KEYBOARD_GAMEPAD_MAX_RAMP_MS, &n)) {
            kg->ramp_ms = n;
        } else {
            LOGW("Keyboard gamepad: ramp_ms must be 0 to %d, not '%.*s'; "
                 "ignored", SC_KEYBOARD_GAMEPAD_MAX_RAMP_MS, (int) value_len,
                 value);
        }
        return true;
    }
    if (name_len == 12 && !strncmp(name, "walk_percent", 12)) {
        if (kg_parse_number(value, value_len, 1, 100, &n)) {
            kg->walk_percent = (uint8_t) n;
        } else {
            LOGW("Keyboard gamepad: walk_percent must be 1 to 100, not "
                 "'%.*s'; ignored", (int) value_len, value);
        }
        return true;
    }
    if (name_len == 11 && !strncmp(name, "mouse_stick", 11)) {
        if (value_len == 3 && !strncmp(value, "off", 3)) {
            kg->mouse_stick = SC_KEYBOARD_GAMEPAD_MOUSE_STICK_OFF;
        } else if (value_len == 5 && !strncmp(value, "right", 5)) {
            kg->mouse_stick = SC_KEYBOARD_GAMEPAD_MOUSE_STICK_RIGHT;
        } else if (value_len == 4 && !strncmp(value, "left", 4)) {
            kg->mouse_stick = SC_KEYBOARD_GAMEPAD_MOUSE_STICK_LEFT;
        } else {
            LOGW("Keyboard gamepad: mouse_stick must be off, right or left, "
                 "not '%.*s'; ignored", (int) value_len, value);
        }
        return true;
    }
    if (name_len == 17 && !strncmp(name, "mouse_sensitivity", 17)) {
        if (kg_parse_number(value, value_len, 1, 1000, &n)) {
            kg->mouse_sensitivity = n;
        } else {
            LOGW("Keyboard gamepad: mouse_sensitivity must be 1 to 1000, not "
                 "'%.*s'; ignored", (int) value_len, value);
        }
        return true;
    }
    if (name_len == 4 && !strncmp(name, "socd", 4)) {
        if (kg_parse_socd(value, value_len, &socd)) {
            for (size_t i = 0; i < SC_KEYBOARD_GAMEPAD_PAD_COUNT; ++i) {
                kg->socd[i] = socd;
            }
        } else {
            LOGW("Keyboard gamepad: socd must be last or neutral, not "
                 "'%.*s'; ignored", (int) value_len, value);
        }
        return true;
    }
    static const struct {
        const char *name;
        enum kg_pad pad;
    } pads[] = {
        {"socd_dpad", KG_DPAD},
        {"socd_left_stick", KG_LEFT_STICK},
        {"socd_right_stick", KG_RIGHT_STICK},
    };
    for (size_t i = 0; i < ARRAY_LEN(pads); ++i) {
        if (strlen(pads[i].name) == name_len
                && !strncmp(name, pads[i].name, name_len)) {
            if (kg_parse_socd(value, value_len, &socd)) {
                kg->socd[pads[i].pad] = socd;
            } else {
                LOGW("Keyboard gamepad: %s must be last or neutral, not "
                     "'%.*s'; ignored", pads[i].name, (int) value_len, value);
            }
            return true;
        }
    }
    return false;
}

// "control=key/key,control=key,setting=value": unknown controls, keys and
// settings are skipped
static void
kg_parse_spec(struct sc_keyboard_gamepad *kg, const char *spec) {
    const char *p = spec;
    while (*p) {
        const char *item_end = strchr(p, ',');
        size_t item_len = item_end ? (size_t) (item_end - p) : strlen(p);
        const char *eq = memchr(p, '=', item_len);
        if (item_len && !eq) {
            LOGW("Keyboard gamepad: '%.*s' is not control=keys; ignored",
                 (int) item_len, p);
        } else if (item_len) {
            const char *keys_end = p + item_len;
            const struct sc_keyboard_gamepad_control *control =
                kg_find_control(p, eq - p);
            if (control) {
                const char *k = eq + 1;
                while (k < keys_end) {
                    const char *sep = memchr(k, '/', keys_end - k);
                    const char *k_end = sep ? sep : keys_end;
                    if (k_end > k) {
                        kg_add_key(kg, control, k, k_end - k);
                    }
                    k = k_end + 1;
                }
            } else if (!kg_parse_setting(kg, p, eq - p, eq + 1,
                                         keys_end - (eq + 1))) {
                LOGW("Keyboard gamepad: unknown control '%.*s'; ignored",
                     (int) (eq - p), p);
            }
        }
        if (!item_end) {
            break;
        }
        p = item_end + 1;
    }
}

static struct sc_keyboard_gamepad_key *
kg_find_key(struct sc_keyboard_gamepad *kg,
            enum sc_keyboard_gamepad_input input, uint32_t code) {
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].input == input && kg->keys[i].code == code) {
            return &kg->keys[i];
        }
    }
    return NULL;
}

static void
kg_send_button(struct sc_keyboard_gamepad *kg, enum sc_gamepad_button button,
               bool down) {
    struct sc_gamepad_button_event evt = {
        .gamepad_id = SC_KEYBOARD_GAMEPAD_ID,
        .action = down ? SC_ACTION_DOWN : SC_ACTION_UP,
        .button = button,
    };
    kg->gp->ops->process_gamepad_button(kg->gp, &evt);
}

static void
kg_send_axis(struct sc_keyboard_gamepad *kg, enum sc_gamepad_axis axis,
             int16_t value) {
    struct sc_gamepad_axis_event evt = {
        .gamepad_id = SC_KEYBOARD_GAMEPAD_ID,
        .axis = axis,
        .value = value,
    };
    kg->gp->ops->process_gamepad_axis(kg->gp, &evt);
}

void
sc_keyboard_gamepad_init(struct sc_keyboard_gamepad *kg,
                         struct sc_gamepad_processor *gp, const char *spec,
                         const struct sc_keyboard_gamepad_timer *timer) {
    assert(gp && gp->ops);
    kg->gp = gp;
    kg->key_count = 0;
    kg->press_count = 0;
    kg->ramp_ms = 0;
    kg->walk_percent = KG_DEFAULT_WALK_PERCENT;
    for (size_t i = 0; i < SC_KEYBOARD_GAMEPAD_PAD_COUNT; ++i) {
        kg->socd[i] = SC_KEYBOARD_GAMEPAD_SOCD_LAST;
    }
    kg->mouse_stick = SC_KEYBOARD_GAMEPAD_MOUSE_STICK_OFF;
    kg->mouse_sensitivity = KG_DEFAULT_MOUSE_SENSITIVITY;
    kg->mouse_dx = 0;
    kg->mouse_dy = 0;
    kg->mouse_x = 0;
    kg->mouse_y = 0;
    kg->mouse_motion_ms = 0;
    kg->ticking = false;
    memset(kg->x, 0, sizeof(kg->x));
    memset(kg->y, 0, sizeof(kg->y));
    memset(kg->magnitude, 0, sizeof(kg->magnitude));
    memset(kg->sent_x, 0, sizeof(kg->sent_x));
    memset(kg->sent_y, 0, sizeof(kg->sent_y));
    memset(kg->ramping, 0, sizeof(kg->ramping));
    kg->tick_ms = 0;
    kg->timer = timer;

    if (!spec || !*spec) {
        spec = SC_KEYBOARD_GAMEPAD_DEFAULT_SPEC;
    }
    kg_parse_spec(kg, spec);
    static const char *const mouse_sticks[] = {"off", "right", "left"};
    LOGI("Keyboard gamepad: %zu keys, ramp %" PRIu32 " ms, walk %u%%, mouse "
         "stick %s at %" PRIu32 "%% (%s)", kg->key_count, kg->ramp_ms,
         kg->walk_percent, mouse_sticks[kg->mouse_stick],
         kg->mouse_sensitivity, spec);
}

void
sc_keyboard_gamepad_plug(struct sc_keyboard_gamepad *kg) {
    struct sc_gamepad_device_event evt = {
        .gamepad_id = SC_KEYBOARD_GAMEPAD_ID,
        .name = "Keyboard gamepad",
    };
    kg->gp->ops->process_gamepad_added(kg->gp, &evt);
}

static bool
kg_control_held(const struct sc_keyboard_gamepad *kg,
                const struct sc_keyboard_gamepad_control *control) {
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].control == control && kg->keys[i].pressed) {
            return true;
        }
    }
    return false;
}

static bool
kg_walk_held(const struct sc_keyboard_gamepad *kg) {
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].pressed && kg->keys[i].control->kind == KG_KIND_WALK) {
            return true;
        }
    }
    return false;
}

// Where the held direction keys point a pad on one axis: -1, 0 or 1. Of two
// opposite directions, the last pressed counts (socd=last), as no pad points
// both ways, or they cancel out (socd=neutral).
static int8_t
kg_pad_direction(const struct sc_keyboard_gamepad *kg, enum kg_pad pad,
                 bool vertical) {
    uint32_t last = 0;
    int8_t direction = 0;
    bool negative = false;
    bool positive = false;
    for (size_t i = 0; i < kg->key_count; ++i) {
        const struct sc_keyboard_gamepad_key *key = &kg->keys[i];
        const struct sc_keyboard_gamepad_control *c = key->control;
        if (!key->pressed || c->kind != KG_KIND_DIRECTION || c->pad != pad
                || c->vertical != vertical) {
            continue;
        }
        if (c->sign < 0) {
            negative = true;
        } else {
            positive = true;
        }
        if (key->pressed > last) {
            last = key->pressed;
            direction = c->sign;
        }
    }
    if (kg->socd[pad] == SC_KEYBOARD_GAMEPAD_SOCD_NEUTRAL && negative
            && positive) {
        return 0;
    }
    return direction;
}

static enum sc_gamepad_button
kg_dpad_button(bool vertical, int8_t direction) {
    if (vertical) {
        return direction < 0 ? SC_GAMEPAD_BUTTON_DPAD_UP
                             : SC_GAMEPAD_BUTTON_DPAD_DOWN;
    }
    return direction < 0 ? SC_GAMEPAD_BUTTON_DPAD_LEFT
                         : SC_GAMEPAD_BUTTON_DPAD_RIGHT;
}

// Moves the D-pad to (x, y): the buttons it leaves are released before the
// ones it reaches are pressed, so that it never points two ways at once
static void
kg_move_dpad(struct sc_keyboard_gamepad *kg, int8_t x, int8_t y) {
    int8_t old_x = kg->x[KG_DPAD];
    int8_t old_y = kg->y[KG_DPAD];
    kg->x[KG_DPAD] = x;
    kg->y[KG_DPAD] = y;

    if (old_x && old_x != x) {
        kg_send_button(kg, kg_dpad_button(false, old_x), false);
    }
    if (old_y && old_y != y) {
        kg_send_button(kg, kg_dpad_button(true, old_y), false);
    }
    if (x && x != old_x) {
        kg_send_button(kg, kg_dpad_button(false, x), true);
    }
    if (y && y != old_y) {
        kg_send_button(kg, kg_dpad_button(true, y), true);
    }
}

// The value of an axis pushed by magnitude in a direction: a stick fully
// left or up reports INT16_MIN, as SDL does
static int16_t
kg_axis_value(int8_t direction, int32_t magnitude) {
    if (!direction) {
        return 0;
    }
    if (direction < 0) {
        return magnitude == INT16_MAX ? INT16_MIN : (int16_t) -magnitude;
    }
    return (int16_t) magnitude;
}

// Sends a stick's position, in one report when the processor takes stick
// events, else as the two axis events, the axis that comes back toward the
// center first, so that the stick never leaves its round gate between them
// The stick the mouse moves, or -1
static int
kg_mouse_pad(const struct sc_keyboard_gamepad *kg) {
    switch (kg->mouse_stick) {
        case SC_KEYBOARD_GAMEPAD_MOUSE_STICK_RIGHT:
            return KG_RIGHT_STICK;
        case SC_KEYBOARD_GAMEPAD_MOUSE_STICK_LEFT:
            return KG_LEFT_STICK;
        default:
            return -1;
    }
}

static void
kg_send_stick(struct sc_keyboard_gamepad *kg, enum kg_pad pad) {
    assert(pad == KG_LEFT_STICK || pad == KG_RIGHT_STICK);
    int8_t x = kg->x[pad];
    int8_t y = kg->y[pad];
    int32_t magnitude = kg->magnitude[pad];
    if (x && y) {
        magnitude = magnitude * KG_STICK_DIAGONAL / INT16_MAX;
    }
    int16_t vx = kg_axis_value(x, magnitude);
    int16_t vy = kg_axis_value(y, magnitude);
    if (!x && !y && (int) pad == kg_mouse_pad(kg)) {
        // The mouse moves this stick while its keys are idle
        vx = kg->mouse_x;
        vy = kg->mouse_y;
    }
    int16_t old_vx = kg->sent_x[pad];
    int16_t old_vy = kg->sent_y[pad];
    if (vx == old_vx && vy == old_vy) {
        return;
    }
    kg->sent_x[pad] = vx;
    kg->sent_y[pad] = vy;

    if (kg->gp->ops->process_gamepad_stick) {
        struct sc_gamepad_stick_event evt = {
            .gamepad_id = SC_KEYBOARD_GAMEPAD_ID,
            .stick = pad == KG_LEFT_STICK ? SC_GAMEPAD_STICK_LEFT
                                          : SC_GAMEPAD_STICK_RIGHT,
            .x = vx,
            .y = vy,
        };
        kg->gp->ops->process_gamepad_stick(kg->gp, &evt);
        return;
    }

    enum sc_gamepad_axis axis_x = pad == KG_LEFT_STICK
                                ? SC_GAMEPAD_AXIS_LEFTX
                                : SC_GAMEPAD_AXIS_RIGHTX;
    enum sc_gamepad_axis axis_y = pad == KG_LEFT_STICK
                                ? SC_GAMEPAD_AXIS_LEFTY
                                : SC_GAMEPAD_AXIS_RIGHTY;
    bool y_first = abs(vy) < abs(old_vy);
    if (y_first && vy != old_vy) {
        kg_send_axis(kg, axis_y, vy);
    }
    if (vx != old_vx) {
        kg_send_axis(kg, axis_x, vx);
    }
    if (!y_first && vy != old_vy) {
        kg_send_axis(kg, axis_y, vy);
    }
}

// How far the sticks may go: all the way, or walk_percent of it with the walk
// key held
static int32_t
kg_stick_cap(const struct sc_keyboard_gamepad *kg) {
    if (kg_walk_held(kg)) {
        return INT16_MAX * kg->walk_percent / 100;
    }
    return INT16_MAX;
}

// Has the owner tick, from now_ms, until sc_keyboard_gamepad_tick() says
// there is nothing more to do
static void
kg_start_ticking(struct sc_keyboard_gamepad *kg, uint64_t now_ms) {
    if (kg->ticking) {
        return;
    }
    kg->ticking = true;
    kg->tick_ms = now_ms;
    if (kg->timer) {
        kg->timer->arm(kg->timer->userdata);
    }
}

static int32_t
kg_ramp_step(const struct sc_keyboard_gamepad *kg, uint64_t elapsed_ms) {
    assert(kg->ramp_ms);
    uint64_t step = INT16_MAX * elapsed_ms / kg->ramp_ms;
    return step > INT16_MAX ? INT16_MAX : (int32_t) step;
}

// Moves a stick toward (x, y) at now_ms: at once, back toward the center or
// without a ramp; else from where it is, ramping on toward the cap
static void
kg_move_stick(struct sc_keyboard_gamepad *kg, enum kg_pad pad, int8_t x,
              int8_t y, uint64_t now_ms) {
    kg->x[pad] = x;
    kg->y[pad] = y;

    int32_t cap = kg_stick_cap(kg);
    if (!x && !y) {
        kg->magnitude[pad] = 0;
        kg->ramping[pad] = false;
    } else if (!kg->ramp_ms || kg->magnitude[pad] >= cap) {
        kg->magnitude[pad] = cap;
        kg->ramping[pad] = false;
    } else if (!kg->ramping[pad]) {
        // Start with one tick's worth, so that the key moves the stick at
        // once, then let the timer carry it on
        int32_t magnitude = kg->magnitude[pad]
                          + kg_ramp_step(kg, KG_FIRST_STEP_MS);
        if (magnitude >= cap) {
            kg->magnitude[pad] = cap;
        } else {
            kg->magnitude[pad] = magnitude;
            kg->ramping[pad] = true;
            kg_start_ticking(kg, now_ms);
        }
    }
    // Else the stick ramps on, from where it is, in the new direction
    kg_send_stick(kg, pad);
}

static void
kg_apply_key(struct sc_keyboard_gamepad *kg,
             struct sc_keyboard_gamepad_key *key, bool down,
             uint64_t now_ms);

// The mouse's motion since the last tick, elapsed_ms long, as a stick
// position: a velocity, clamped to the stick's round gate
static void
kg_mouse_to_stick(struct sc_keyboard_gamepad *kg, uint64_t elapsed_ms) {
    int64_t dt = elapsed_ms ? (int64_t) elapsed_ms : 1;
    // INT16_MAX at KG_MOUSE_FULL_PX per 8 ms at 100%
    int64_t vx = (int64_t) kg->mouse_dx * INT16_MAX * 8 * kg->mouse_sensitivity
               / (KG_MOUSE_FULL_PX * 100 * dt);
    int64_t vy = (int64_t) kg->mouse_dy * INT16_MAX * 8 * kg->mouse_sensitivity
               / (KG_MOUSE_FULL_PX * 100 * dt);
    int64_t norm2 = vx * vx + vy * vy;
    if (norm2 > (int64_t) INT16_MAX * INT16_MAX) {
        // Scale the vector down onto the gate, by a rational close to
        // INT16_MAX / sqrt(norm2): compare against the squares in steps
        int64_t scale = INT16_MAX;
        int64_t lo = 0;
        int64_t hi = INT16_MAX;
        while (lo < hi) {
            int64_t mid = (lo + hi + 1) / 2;
            int64_t sx = vx * mid / scale;
            int64_t sy = vy * mid / scale;
            if (sx * sx + sy * sy <= (int64_t) INT16_MAX * INT16_MAX) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        vx = vx * lo / scale;
        vy = vy * lo / scale;
    }
    kg->mouse_x = (int16_t) vx;
    kg->mouse_y = (int16_t) vy;
    kg->mouse_dx = 0;
    kg->mouse_dy = 0;
}

bool
sc_keyboard_gamepad_tick(struct sc_keyboard_gamepad *kg, uint64_t now_ms) {
    uint64_t elapsed_ms = now_ms > kg->tick_ms ? now_ms - kg->tick_ms : 0;
    kg->tick_ms = now_ms;
    bool more = false;

    for (enum kg_pad pad = KG_LEFT_STICK; pad <= KG_RIGHT_STICK; ++pad) {
        if (!kg->ramping[pad]) {
            continue;
        }
        int32_t cap = kg_stick_cap(kg);
        int32_t magnitude = kg->magnitude[pad] + kg_ramp_step(kg, elapsed_ms);
        if (magnitude >= cap) {
            kg->magnitude[pad] = cap;
            kg->ramping[pad] = false;
        } else {
            kg->magnitude[pad] = magnitude;
            more = true;
        }
        kg_send_stick(kg, pad);
    }

    // The wheel's notches are released once their moment is over
    for (size_t i = 0; i < kg->key_count; ++i) {
        struct sc_keyboard_gamepad_key *key = &kg->keys[i];
        if (!key->pressed || key->input != SC_KEYBOARD_GAMEPAD_INPUT_WHEEL) {
            continue;
        }
        if (now_ms >= key->release_ms) {
            kg_apply_key(kg, key, false, now_ms);
        } else {
            more = true;
        }
    }

    int mouse_pad = kg_mouse_pad(kg);
    if (mouse_pad >= 0) {
        bool moved = kg->mouse_dx || kg->mouse_dy;
        if (moved) {
            kg_mouse_to_stick(kg, elapsed_ms);
            kg->mouse_motion_ms = now_ms;
        } else if ((kg->mouse_x || kg->mouse_y)
                && now_ms >= kg->mouse_motion_ms + KG_MOUSE_HOLD_MS) {
            // The mouse stopped
            kg->mouse_x = 0;
            kg->mouse_y = 0;
        }
        if (kg->mouse_x || kg->mouse_y) {
            more = true;
        }
        kg_send_stick(kg, mouse_pad);
    }

    kg->ticking = more;
    return more;
}

bool
sc_keyboard_gamepad_takes_mouse(const struct sc_keyboard_gamepad *kg) {
    return kg->mouse_stick != SC_KEYBOARD_GAMEPAD_MOUSE_STICK_OFF;
}

void
sc_keyboard_gamepad_handle_mouse_motion(struct sc_keyboard_gamepad *kg,
                                        int32_t xrel, int32_t yrel,
                                        uint64_t now_ms) {
    if (kg_mouse_pad(kg) < 0 || (!xrel && !yrel)) {
        return;
    }
    kg->mouse_dx += xrel;
    kg->mouse_dy += yrel;
    // The stick moves at the next tick, with the motion of the whole tick
    kg_start_ticking(kg, now_ms);
}

bool
sc_keyboard_gamepad_handle_mouse_button(struct sc_keyboard_gamepad *kg,
                                        uint32_t button, bool down,
                                        uint64_t now_ms) {
    struct sc_keyboard_gamepad_key *key =
        kg_find_key(kg, SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON, button);
    if (!down) {
        if (!key || !key->pressed) {
            return false;
        }
        kg_apply_key(kg, key, false, now_ms);
        return true;
    }
    if (key && !key->pressed) {
        kg_apply_key(kg, key, true, now_ms);
    }
    return true;
}

void
sc_keyboard_gamepad_handle_mouse_wheel(struct sc_keyboard_gamepad *kg,
                                       float hscroll, float vscroll,
                                       uint64_t now_ms) {
    struct {
        float amount;
        enum sc_keyboard_gamepad_wheel wheel;
    } notches[] = {
        {vscroll, SC_KEYBOARD_GAMEPAD_WHEEL_UP},
        {-vscroll, SC_KEYBOARD_GAMEPAD_WHEEL_DOWN},
        {hscroll, SC_KEYBOARD_GAMEPAD_WHEEL_RIGHT},
        {-hscroll, SC_KEYBOARD_GAMEPAD_WHEEL_LEFT},
    };
    for (size_t i = 0; i < ARRAY_LEN(notches); ++i) {
        if (notches[i].amount <= 0) {
            continue;
        }
        struct sc_keyboard_gamepad_key *key =
            kg_find_key(kg, SC_KEYBOARD_GAMEPAD_INPUT_WHEEL, notches[i].wheel);
        if (!key) {
            continue;
        }
        // A notch presses the control for a moment; another notch meanwhile
        // holds it longer
        key->release_ms = now_ms + KG_WHEEL_PULSE_MS;
        if (!key->pressed) {
            kg_apply_key(kg, key, true, now_ms);
        }
        kg_start_ticking(kg, now_ms);
    }
}

// Presses or releases a key on the gamepad, at now_ms
static void
kg_apply_key(struct sc_keyboard_gamepad *kg,
             struct sc_keyboard_gamepad_key *key, bool down,
             uint64_t now_ms) {
    const struct sc_keyboard_gamepad_control *c = key->control;
    bool was_held = kg_control_held(kg, c);
    key->pressed = down ? ++kg->press_count : 0;

    if (c->kind == KG_KIND_DIRECTION) {
        int8_t x = kg_pad_direction(kg, c->pad, false);
        int8_t y = kg_pad_direction(kg, c->pad, true);
        if (c->pad == KG_DPAD) {
            kg_move_dpad(kg, x, y);
        } else {
            kg_move_stick(kg, c->pad, x, y, now_ms);
        }
        return;
    }

    // Another key of the control may hold it pressed already, or still
    bool held = kg_control_held(kg, c);
    if (held == was_held) {
        return;
    }
    switch (c->kind) {
        case KG_KIND_BUTTON:
            kg_send_button(kg, c->button, held);
            break;
        case KG_KIND_TRIGGER:
            kg_send_axis(kg, c->axis, held ? INT16_MAX : 0);
            break;
        case KG_KIND_WALK:
            // The sticks' cap changed: a pushed stick comes down to it at
            // once, or ramps on up to it
            for (enum kg_pad pad = KG_LEFT_STICK; pad <= KG_RIGHT_STICK;
                    ++pad) {
                if (kg->x[pad] || kg->y[pad]) {
                    kg_move_stick(kg, pad, kg->x[pad], kg->y[pad], now_ms);
                }
            }
            break;
        default:
            assert(!"unreachable");
            break;
    }
}

bool
sc_keyboard_gamepad_handle_key(struct sc_keyboard_gamepad *kg,
                               const SDL_KeyboardEvent *event) {
    struct sc_keyboard_gamepad_key *key =
        kg_find_key(kg, SC_KEYBOARD_GAMEPAD_INPUT_KEY, event->scancode);
    if (!key) {
        return false;
    }

    uint64_t now_ms = event->timestamp / 1000000;
    bool down = event->type == SDL_EVENT_KEY_DOWN;
    if (!down) {
        // A held key is released whatever modifier is down by now; the
        // release of a key that typed (pressed with a modifier) types too
        if (!key->pressed) {
            return false;
        }
        kg_apply_key(kg, key, false, now_ms);
        return true;
    }

    if (event->repeat) {
        // A held gamepad key stays pressed by itself, even once a modifier is
        // down; the repeats of a key that typed keep typing
        return key->pressed;
    }

    // Key combinations are not gamepad keys
    if (event->mod & (SDL_KMOD_CTRL | SDL_KMOD_ALT | SDL_KMOD_GUI)) {
        return false;
    }

    if (!key->pressed) {
        kg_apply_key(kg, key, true, now_ms);
    }
    return true;
}

void
sc_keyboard_gamepad_release_all(struct sc_keyboard_gamepad *kg) {
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].pressed) {
            kg_apply_key(kg, &kg->keys[i], false, kg->tick_ms);
        }
    }
}
