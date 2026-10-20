#include "keyboard_gamepad.h"

#include <stdint.h>
#include <string.h>

#include "input_events.h"
#include "util/log.h"

#define SC_KEYBOARD_GAMEPAD_DEFAULT_SPEC \
    "dpad_up=Up/W,dpad_down=Down/S,dpad_left=Left/A,dpad_right=Right/D," \
    "a=Space,b=Escape,x=C,y=V,start=Return/Keypad_Enter,back=Backspace," \
    "left_shoulder=Q,right_shoulder=E,left_trigger=Z,right_trigger=X"

struct kg_control {
    const char *name;
    enum sc_keyboard_gamepad_kind kind;
    enum sc_gamepad_button button;
};

static const struct kg_control kg_controls[] = {
    {"dpad_up", SC_KEYBOARD_GAMEPAD_KIND_UP, SC_GAMEPAD_BUTTON_DPAD_UP},
    {"dpad_down", SC_KEYBOARD_GAMEPAD_KIND_DOWN, SC_GAMEPAD_BUTTON_DPAD_DOWN},
    {"dpad_left", SC_KEYBOARD_GAMEPAD_KIND_LEFT, SC_GAMEPAD_BUTTON_DPAD_LEFT},
    {"dpad_right", SC_KEYBOARD_GAMEPAD_KIND_RIGHT,
     SC_GAMEPAD_BUTTON_DPAD_RIGHT},
    {"a", SC_KEYBOARD_GAMEPAD_KIND_BUTTON, SC_GAMEPAD_BUTTON_SOUTH},
    {"b", SC_KEYBOARD_GAMEPAD_KIND_BUTTON, SC_GAMEPAD_BUTTON_EAST},
    {"x", SC_KEYBOARD_GAMEPAD_KIND_BUTTON, SC_GAMEPAD_BUTTON_WEST},
    {"y", SC_KEYBOARD_GAMEPAD_KIND_BUTTON, SC_GAMEPAD_BUTTON_NORTH},
    {"start", SC_KEYBOARD_GAMEPAD_KIND_BUTTON, SC_GAMEPAD_BUTTON_START},
    {"back", SC_KEYBOARD_GAMEPAD_KIND_BUTTON, SC_GAMEPAD_BUTTON_BACK},
    {"guide", SC_KEYBOARD_GAMEPAD_KIND_BUTTON, SC_GAMEPAD_BUTTON_GUIDE},
    {"left_shoulder", SC_KEYBOARD_GAMEPAD_KIND_BUTTON,
     SC_GAMEPAD_BUTTON_LEFT_SHOULDER},
    {"right_shoulder", SC_KEYBOARD_GAMEPAD_KIND_BUTTON,
     SC_GAMEPAD_BUTTON_RIGHT_SHOULDER},
    {"left_stick", SC_KEYBOARD_GAMEPAD_KIND_BUTTON,
     SC_GAMEPAD_BUTTON_LEFT_STICK},
    {"right_stick", SC_KEYBOARD_GAMEPAD_KIND_BUTTON,
     SC_GAMEPAD_BUTTON_RIGHT_STICK},
    {"left_trigger", SC_KEYBOARD_GAMEPAD_KIND_LEFT_TRIGGER,
     SC_GAMEPAD_BUTTON_UNKNOWN},
    {"right_trigger", SC_KEYBOARD_GAMEPAD_KIND_RIGHT_TRIGGER,
     SC_GAMEPAD_BUTTON_UNKNOWN},
};

static const struct kg_control *
kg_find_control(const char *name, size_t len) {
    for (size_t i = 0; i < ARRAY_LEN(kg_controls); ++i) {
        const struct kg_control *c = &kg_controls[i];
        if (strlen(c->name) == len && !strncmp(c->name, name, len)) {
            return c;
        }
    }
    return NULL;
}

// SDL key name of "name" (len bytes), with "_" standing for a space
static SDL_Scancode
kg_scancode(const char *name, size_t len) {
    char buf[32];
    if (!len || len >= sizeof(buf)) {
        return SDL_SCANCODE_UNKNOWN;
    }
    for (size_t i = 0; i < len; ++i) {
        buf[i] = name[i] == '_' ? ' ' : name[i];
    }
    buf[len] = '\0';
    return SDL_GetScancodeFromName(buf);
}

static void
kg_add_key(struct sc_keyboard_gamepad *kg, const struct kg_control *control,
           const char *name, size_t len) {
    SDL_Scancode scancode = kg_scancode(name, len);
    if (scancode == SDL_SCANCODE_UNKNOWN) {
        LOGW("Keyboard gamepad: unknown key '%.*s' for %s; ignored",
             (int) len, name, control->name);
        return;
    }
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].scancode == scancode) {
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
        .scancode = scancode,
        .kind = control->kind,
        .button = control->button,
        .held = false,
    };
}

// "control=key/key,control=key": unknown controls and keys are skipped
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
            const struct kg_control *control = kg_find_control(p, eq - p);
            if (!control) {
                LOGW("Keyboard gamepad: unknown control '%.*s'; ignored",
                     (int) (eq - p), p);
            } else {
                const char *k = eq + 1;
                const char *keys_end = p + item_len;
                while (k < keys_end) {
                    const char *sep = memchr(k, '/', keys_end - k);
                    const char *k_end = sep ? sep : keys_end;
                    if (k_end > k) {
                        kg_add_key(kg, control, k, k_end - k);
                    }
                    k = k_end + 1;
                }
            }
        }
        if (!item_end) {
            break;
        }
        p = item_end + 1;
    }
}

static struct sc_keyboard_gamepad_key *
kg_find_key(struct sc_keyboard_gamepad *kg, SDL_Scancode scancode) {
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].scancode == scancode) {
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
                         struct sc_gamepad_processor *gp, const char *spec) {
    assert(gp && gp->ops);
    kg->gp = gp;
    kg->key_count = 0;
    kg->up = false;
    kg->down = false;
    kg->left = false;
    kg->right = false;

    if (!spec || !*spec) {
        spec = SC_KEYBOARD_GAMEPAD_DEFAULT_SPEC;
    }
    kg_parse_spec(kg, spec);
    LOGI("Keyboard gamepad: %zu keys (%s)", kg->key_count, spec);
}

void
sc_keyboard_gamepad_plug(struct sc_keyboard_gamepad *kg) {
    struct sc_gamepad_device_event evt = {
        .gamepad_id = SC_KEYBOARD_GAMEPAD_ID,
        .name = "Keyboard gamepad",
    };
    kg->gp->ops->process_gamepad_added(kg->gp, &evt);
}

// Presses or releases a key on the gamepad: a direction key also moves the
// left stick, and releasing one restores a direction still held
static void
kg_apply_key(struct sc_keyboard_gamepad *kg,
             struct sc_keyboard_gamepad_key *key, bool down) {
    key->held = down;
    bool *held;
    switch (key->kind) {
        case SC_KEYBOARD_GAMEPAD_KIND_BUTTON:
            kg_send_button(kg, key->button, down);
            return;
        case SC_KEYBOARD_GAMEPAD_KIND_LEFT_TRIGGER:
            kg_send_axis(kg, SC_GAMEPAD_AXIS_LEFT_TRIGGER,
                         down ? INT16_MAX : 0);
            return;
        case SC_KEYBOARD_GAMEPAD_KIND_RIGHT_TRIGGER:
            kg_send_axis(kg, SC_GAMEPAD_AXIS_RIGHT_TRIGGER,
                         down ? INT16_MAX : 0);
            return;
        case SC_KEYBOARD_GAMEPAD_KIND_UP:
            held = &kg->up;
            break;
        case SC_KEYBOARD_GAMEPAD_KIND_DOWN:
            held = &kg->down;
            break;
        case SC_KEYBOARD_GAMEPAD_KIND_LEFT:
            held = &kg->left;
            break;
        default:
            assert(key->kind == SC_KEYBOARD_GAMEPAD_KIND_RIGHT);
            held = &kg->right;
            break;
    }

    if (*held == down) {
        return;
    }
    *held = down;

    // The D-pad and the left stick both follow the direction keys
    kg_send_button(kg, key->button, down);
    kg_send_axis(kg, SC_GAMEPAD_AXIS_LEFTX,
                 kg->right ? INT16_MAX : kg->left ? INT16_MIN : 0);
    kg_send_axis(kg, SC_GAMEPAD_AXIS_LEFTY,
                 kg->down ? INT16_MAX : kg->up ? INT16_MIN : 0);
}

bool
sc_keyboard_gamepad_handle_key(struct sc_keyboard_gamepad *kg,
                               const SDL_KeyboardEvent *event) {
    struct sc_keyboard_gamepad_key *key = kg_find_key(kg, event->scancode);
    if (!key) {
        return false;
    }

    bool down = event->type == SDL_EVENT_KEY_DOWN;
    if (!down) {
        // A held key is released whatever modifier is down by now; the
        // release of a key that typed (pressed with a modifier) types too
        if (!key->held) {
            return false;
        }
        kg_apply_key(kg, key, false);
        return true;
    }

    if (event->repeat) {
        // A held gamepad key stays pressed by itself, even once a modifier is
        // down; the repeats of a key that typed keep typing
        return key->held;
    }

    // Key combinations are not gamepad keys
    if (event->mod & (SDL_KMOD_CTRL | SDL_KMOD_ALT | SDL_KMOD_GUI)) {
        return false;
    }

    if (!key->held) {
        kg_apply_key(kg, key, true);
    }
    return true;
}

void
sc_keyboard_gamepad_release_all(struct sc_keyboard_gamepad *kg) {
    for (size_t i = 0; i < kg->key_count; ++i) {
        if (kg->keys[i].held) {
            kg_apply_key(kg, &kg->keys[i], false);
        }
    }
}
