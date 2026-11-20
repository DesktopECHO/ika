#include "keyboard_touch.h"

#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "input_events.h"
#include "util/log.h"

#define KT_DEFAULT_AIM_SENSITIVITY 100
#define KT_DEFAULT_JOYSTICK_RAMP_MS 60
#define KT_DEFAULT_WALK_PERCENT 50
#define KT_DEFAULT_SPRINT_PERCENT 200
#define KT_MAX_RAMP_MS 1000

// A ramp's first step, as the key goes down, so that the finger moves at once
#define KT_RAMP_FIRST_STEP 0.25f

// A skill cast reaches its radius once the pointer is this many display
// heights from the character
#define KT_CAST_FULL 0.5f

// The motion of one mouse event is cut in at most this many pieces at the
// aim's edge (each piece a radius long)
#define KT_AIM_MAX_HANDOFFS 64

#define KT_JOYSTICK_UP SC_KEYBOARD_TOUCH_JOYSTICK_UP
#define KT_JOYSTICK_DOWN SC_KEYBOARD_TOUCH_JOYSTICK_DOWN
#define KT_JOYSTICK_LEFT SC_KEYBOARD_TOUCH_JOYSTICK_LEFT
#define KT_JOYSTICK_RIGHT SC_KEYBOARD_TOUCH_JOYSTICK_RIGHT
#define KT_JOYSTICK_WALK SC_KEYBOARD_TOUCH_JOYSTICK_WALK
#define KT_JOYSTICK_SPRINT SC_KEYBOARD_TOUCH_JOYSTICK_SPRINT

// The longest file read
#define KT_MAX_FILE_SIZE 65536

static const struct {
    const char *name;
    int16_t target;
    const char *default_key; // NULL: none
} kt_joystick_keys[] = {
    {"joystick_up", KT_JOYSTICK_UP, "W"},
    {"joystick_down", KT_JOYSTICK_DOWN, "S"},
    {"joystick_left", KT_JOYSTICK_LEFT, "A"},
    {"joystick_right", KT_JOYSTICK_RIGHT, "D"},
    {"joystick_walk", KT_JOYSTICK_WALK, NULL},
    {"joystick_sprint", KT_JOYSTICK_SPRINT, NULL},
};

// cos(45°): a joystick pushed on a diagonal is as far from its center as on
// an axis
#define KT_DIAGONAL 0.70710678f

static bool
kt_name_is(const char *name, size_t len, const char *expected) {
    return strlen(expected) == len && !strncmp(name, expected, len);
}

// A number from 0 to max, with up to 6 decimals: "0", "1", "0.85", ".5";
// rounded once, as a C literal is, so that a value written and read again
// stays the same
static bool
kt_parse_decimal(const char *s, size_t len, float max, float *out) {
    static const double pow10[] = {1, 10, 100, 1e3, 1e4, 1e5, 1e6};
    uint64_t mantissa = 0;
    bool dot = false;
    bool digits = false;
    size_t decimals = 0;
    for (size_t i = 0; i < len; ++i) {
        char c = s[i];
        if (c == '.' && !dot) {
            dot = true;
        } else if (c >= '0' && c <= '9') {
            digits = true;
            if (dot && ++decimals > 6) {
                return false;
            }
            mantissa = mantissa * 10 + (uint64_t) (c - '0');
            if (mantissa > UINT64_C(1000000000000)) {
                return false;
            }
        } else {
            return false;
        }
    }
    if (!digits) {
        return false;
    }
    double value = (double) mantissa / pow10[decimals];
    if (value > max) {
        return false;
    }
    *out = (float) value;
    return true;
}

// An aspect ratio, as a decimal (1.778) or a fraction (16/9); a blank
// around the slash reaches here as ':'
static bool
kt_parse_aspect(const char *s, size_t len, float *out) {
    const char *slash = memchr(s, '/', len);
    float aspect;
    if (!slash) {
        if (!kt_parse_decimal(s, len, 10, &aspect)) {
            return false;
        }
    } else {
        size_t left = slash - s;
        const char *right = slash + 1;
        size_t right_len = len - left - 1;
        while (left && s[left - 1] == ':') {
            --left;
        }
        while (right_len && *right == ':') {
            ++right;
            --right_len;
        }
        float w, h;
        if (!kt_parse_decimal(s, left, 100000, &w)
                || !kt_parse_decimal(right, right_len, 100000, &h) || !h) {
            return false;
        }
        aspect = w / h;
    }
    if (aspect < 0.1f || aspect > 10) {
        return false;
    }
    *out = aspect;
    return true;
}

static bool
kt_parse_fraction(const char *s, size_t len, float *out) {
    return kt_parse_decimal(s, len, 1, out);
}

// Splits "a:b:c" (len bytes) in at most max parts; returns their count, or
// max + 1 if there are more
static size_t
kt_split(const char *s, size_t len, const char **parts, size_t *lens,
         size_t max) {
    size_t n = 0;
    const char *end = s + len;
    for (;;) {
        const char *sep = memchr(s, ':', end - s);
        const char *part_end = sep ? sep : end;
        if (n == max) {
            return max + 1;
        }
        parts[n] = s;
        lens[n] = part_end - s;
        ++n;
        if (!sep) {
            return n;
        }
        s = sep + 1;
    }
}

// "X:Y" (with_radius false) or "X:Y:R"
static bool
kt_parse_point(const char *s, size_t len, bool with_radius,
               struct sc_keyboard_touch_point *out) {
    const char *parts[3];
    size_t lens[3];
    size_t want = with_radius ? 3 : 2;
    if (kt_split(s, len, parts, lens, 3) != want) {
        return false;
    }
    float v[3] = {0, 0, 0};
    for (size_t i = 0; i < want; ++i) {
        if (!kt_parse_fraction(parts[i], lens[i], &v[i])) {
            return false;
        }
    }
    if (with_radius && v[2] <= 0) {
        return false;
    }
    *out = (struct sc_keyboard_touch_point) {v[0], v[1], v[2]};
    return true;
}

// A tap's value: "X:Y", or "X:Y:cast:R" for a skill cast
static bool
kt_parse_tap(const char *s, size_t len, struct sc_keyboard_touch_point *out,
             enum sc_keyboard_touch_kind *kind) {
    const char *parts[4];
    size_t lens[4];
    size_t n = kt_split(s, len, parts, lens, 4);
    float v[3] = {0, 0, 0};
    if (n == 2) {
        *kind = SC_KEYBOARD_TOUCH_TAP;
    } else if (n == 4 && kt_name_is(parts[2], lens[2], "cast")
            && kt_parse_fraction(parts[3], lens[3], &v[2]) && v[2] > 0) {
        *kind = SC_KEYBOARD_TOUCH_CAST;
    } else {
        return false;
    }
    if (!kt_parse_fraction(parts[0], lens[0], &v[0])
            || !kt_parse_fraction(parts[1], lens[1], &v[1])) {
        return false;
    }
    *out = (struct sc_keyboard_touch_point) {v[0], v[1], v[2]};
    return true;
}

static struct sc_keyboard_touch_key *
kt_find_key(struct sc_keyboard_touch *kt,
            enum sc_keyboard_gamepad_input input, uint32_t code) {
    for (size_t i = 0; i < kt->key_count; ++i) {
        if (kt->keys[i].input == input && kt->keys[i].code == code) {
            return &kt->keys[i];
        }
    }
    return NULL;
}

static void
kt_add_key(struct sc_keyboard_touch *kt, int16_t target, const char *name,
           size_t len) {
    enum sc_keyboard_gamepad_input input;
    uint32_t code;
    if (!sc_keyboard_gamepad_parse_input(name, len, &input, &code)) {
        LOGW("Touch keys: unknown key '%.*s'; ignored", (int) len, name);
        return;
    }
    if (input == SC_KEYBOARD_GAMEPAD_INPUT_WHEEL) {
        LOGW("Touch keys: the wheel ('%.*s') does not touch; ignored",
             (int) len, name);
        return;
    }
    if (kt_find_key(kt, input, code)) {
        LOGW("Touch keys: key '%.*s' already used; ignored", (int) len, name);
        return;
    }
    if (kt->key_count == SC_KEYBOARD_TOUCH_MAX_KEYS) {
        LOGW("Touch keys: too many keys; '%.*s' ignored", (int) len, name);
        return;
    }
    kt->keys[kt->key_count++] = (struct sc_keyboard_touch_key) {
        .input = input,
        .code = code,
        .target = target,
        .pressed = 0,
    };
}

static void
kt_add_keys(struct sc_keyboard_touch *kt, int16_t target, const char *keys,
            size_t len) {
    const char *end = keys + len;
    while (keys < end) {
        const char *sep = memchr(keys, '/', end - keys);
        const char *k_end = sep ? sep : end;
        if (k_end > keys) {
            kt_add_key(kt, target, keys, k_end - keys);
        }
        keys = k_end + 1;
    }
}

static bool
kt_parse_number(const char *value, size_t len, uint32_t min, uint32_t max,
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

static void
kt_setting_number(const char *name, const char *value, size_t value_len,
                  uint32_t min, uint32_t max, uint32_t *out) {
    if (!kt_parse_number(value, value_len, min, max, out)) {
        LOGW("Touch keys: %s must be %" PRIu32 " to %" PRIu32 ", not '%.*s'; "
             "ignored", name, min, max, (int) value_len, value);
    }
}

// A setting of the spec: true if name is one, whether or not its value was
// good (a bad value is reported and skipped)
static bool
kt_parse_setting(struct sc_keyboard_touch *kt, const char *name,
                 size_t name_len, const char *value, size_t value_len) {
    static const struct {
        const char *name;
        size_t offset;
        uint32_t min;
        uint32_t max;
    } numbers[] = {
        {"aim_sensitivity", offsetof(struct sc_keyboard_touch,
                                     aim_sensitivity), 1, 1000},
        {"joystick_ramp_ms", offsetof(struct sc_keyboard_touch,
                                      joystick_ramp_ms), 0, KT_MAX_RAMP_MS},
        {"joystick_walk_percent", offsetof(struct sc_keyboard_touch,
                                           joystick_walk_percent), 1, 100},
        {"joystick_sprint_percent", offsetof(struct sc_keyboard_touch,
                                             joystick_sprint_percent),
         100, 400},
    };
    static const struct {
        const char *name;
        size_t offset;
        size_t flag;
    } points[] = {
        {"joystick", offsetof(struct sc_keyboard_touch, joystick),
         offsetof(struct sc_keyboard_touch, has_joystick)},
        {"aim", offsetof(struct sc_keyboard_touch, aim),
         offsetof(struct sc_keyboard_touch, has_aim)},
    };

    for (size_t i = 0; i < ARRAY_LEN(points); ++i) {
        if (kt_name_is(name, name_len, points[i].name)) {
            struct sc_keyboard_touch_point *p =
                (void *) ((char *) kt + points[i].offset);
            if (kt_parse_point(value, value_len, true, p)) {
                *(bool *) ((char *) kt + points[i].flag) = true;
            } else {
                LOGW("Touch keys: %s must be X:Y:R, fractions from 0 to 1, "
                     "not '%.*s'; ignored", points[i].name, (int) value_len,
                     value);
            }
            return true;
        }
    }
    for (size_t i = 0; i < ARRAY_LEN(numbers); ++i) {
        if (kt_name_is(name, name_len, numbers[i].name)) {
            kt_setting_number(numbers[i].name, value, value_len,
                              numbers[i].min, numbers[i].max,
                              (uint32_t *) ((char *) kt + numbers[i].offset));
            return true;
        }
    }
    if (kt_name_is(name, name_len, "cast_center")) {
        if (!kt_parse_point(value, value_len, false, &kt->cast_center)) {
            LOGW("Touch keys: cast_center must be X:Y, fractions from 0 to "
                 "1, not '%.*s'; ignored", (int) value_len, value);
        }
        return true;
    }
    if (kt_name_is(name, name_len, "aspect")) {
        float aspect;
        if (kt_parse_aspect(value, value_len, &aspect)) {
            kt->aspect = aspect;
        } else {
            LOGW("Touch keys: aspect must be a display's width / height, "
                 "as 1.778 or 16/9, not '%.*s'; ignored", (int) value_len,
                 value);
        }
        return true;
    }
    for (size_t i = 0; i < ARRAY_LEN(kt_joystick_keys); ++i) {
        if (kt_name_is(name, name_len, kt_joystick_keys[i].name)) {
            kt_add_keys(kt, kt_joystick_keys[i].target, value, value_len);
            return true;
        }
    }
    return false;
}

static void
kt_add_tap(struct sc_keyboard_touch *kt, const char *keys, size_t keys_len,
           const char *value, size_t value_len) {
    struct sc_keyboard_touch_point point;
    enum sc_keyboard_touch_kind kind;
    if (!kt_parse_tap(value, value_len, &point, &kind)) {
        LOGW("Touch keys: '%.*s' must be X:Y or X:Y:cast:R, fractions from 0 "
             "to 1, not '%.*s'; ignored", (int) keys_len, keys,
             (int) value_len, value);
        return;
    }
    if (kt->tap_count == SC_KEYBOARD_TOUCH_MAX_TAPS) {
        LOGW("Touch keys: too many points; '%.*s' ignored", (int) keys_len,
             keys);
        return;
    }
    size_t index = kt->tap_count;
    size_t key_count = kt->key_count;
    kt_add_keys(kt, (int16_t) index, keys, keys_len);
    if (kt->key_count == key_count) {
        // None of its keys was taken
        return;
    }
    kt->taps[index] = point;
    kt->kinds[index] = kind;
    kt->tap_held[index] = 0;
    kt->tap_count++;
}

static bool
kt_has_target_key(const struct sc_keyboard_touch *kt, int target) {
    for (size_t i = 0; i < kt->key_count; ++i) {
        if (kt->keys[i].target == target) {
            return true;
        }
    }
    return false;
}

static void
kt_add_default_joystick_keys(struct sc_keyboard_touch *kt) {
    for (size_t i = 0; i < ARRAY_LEN(kt_joystick_keys); ++i) {
        const char *name = kt_joystick_keys[i].default_key;
        if (!name || kt_has_target_key(kt, kt_joystick_keys[i].target)) {
            continue;
        }
        enum sc_keyboard_gamepad_input input;
        uint32_t code;
        if (sc_keyboard_gamepad_parse_input(name, strlen(name), &input,
                                            &code)
                && !kt_find_key(kt, input, code)
                && kt->key_count < SC_KEYBOARD_TOUCH_MAX_KEYS) {
            kt->keys[kt->key_count++] = (struct sc_keyboard_touch_key) {
                .input = input,
                .code = code,
                .target = kt_joystick_keys[i].target,
                .pressed = 0,
            };
        }
    }
}

static void
kt_parse_spec(struct sc_keyboard_touch *kt, const char *spec) {
    const char *p = spec;
    while (*p) {
        const char *item_end = strchr(p, ',');
        size_t item_len = item_end ? (size_t) (item_end - p) : strlen(p);
        const char *eq = memchr(p, '=', item_len);
        if (item_len && !eq) {
            LOGW("Touch keys: '%.*s' is not keys=X:Y or a setting; ignored",
                 (int) item_len, p);
        } else if (item_len) {
            size_t name_len = eq - p;
            const char *value = eq + 1;
            size_t value_len = p + item_len - value;
            if (!kt_parse_setting(kt, p, name_len, value, value_len)) {
                kt_add_tap(kt, p, name_len, value, value_len);
            }
        }
        if (!item_end) {
            break;
        }
        p = item_end + 1;
    }

    if (kt->has_joystick) {
        kt_add_default_joystick_keys(kt);
    }
}

void
sc_keyboard_touch_init(struct sc_keyboard_touch *kt, const char *spec) {
    memset(kt, 0, sizeof(*kt));
    kt->aim_sensitivity = KT_DEFAULT_AIM_SENSITIVITY;
    kt->joystick_ramp_ms = KT_DEFAULT_JOYSTICK_RAMP_MS;
    kt->joystick_walk_percent = KT_DEFAULT_WALK_PERCENT;
    kt->joystick_sprint_percent = KT_DEFAULT_SPRINT_PERCENT;
    kt->cast_center = (struct sc_keyboard_touch_point) {0.5f, 0.5f, 0};
    if (spec) {
        kt_parse_spec(kt, spec);
    }
    if (!kt->key_count && !kt->has_aim) {
        LOGW("Touch keys: no key touches the display");
    }
}

// Appends text (len bytes) to buf, each run of blanks and commas as sep
static size_t
kt_append_words(char *buf, size_t pos, size_t max, const char *text,
                size_t len, char sep) {
    bool pending = false;
    for (size_t i = 0; i < len; ++i) {
        char c = text[i];
        if (c == ' ' || c == '\t' || c == ',') {
            pending = true;
            continue;
        }
        if (pending && pos < max) {
            buf[pos++] = sep;
        }
        pending = false;
        if (pos < max) {
            buf[pos++] = c;
        }
    }
    return pos;
}

static void
kt_trim(const char **s, size_t *len) {
    while (*len && (**s == ' ' || **s == '\t')) {
        ++*s;
        --*len;
    }
    while (*len && ((*s)[*len - 1] == ' ' || (*s)[*len - 1] == '\t'
                    || (*s)[*len - 1] == '\r' || (*s)[*len - 1] == '\n')) {
        --*len;
    }
}

// Whether name is a setting whose value is keys (separated by blanks)
static bool
kt_is_keys_setting(const char *name, size_t len) {
    for (size_t i = 0; i < ARRAY_LEN(kt_joystick_keys); ++i) {
        if (kt_name_is(name, len, kt_joystick_keys[i].name)) {
            return true;
        }
    }
    return false;
}

// The file's [touch] lines as a spec: "keys = x y" is "key/key=x:y", the
// keys of the joystick "joystick_up = key key" "joystick_up=key/key"
static char *
kt_spec_from_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno != ENOENT) {
            LOGW("Touch keys: could not read %s: %s", path, strerror(errno));
        }
        return NULL;
    }
    char *spec = malloc(KT_MAX_FILE_SIZE + 1);
    if (!spec) {
        LOG_OOM();
        fclose(f);
        return NULL;
    }
    size_t len = 0;
    bool in_section = false;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        const char *p = line;
        size_t n = strlen(p);
        kt_trim(&p, &n);
        if (!n || *p == '#' || *p == ';') {
            continue;
        }
        if (*p == '[') {
            in_section = n == 7 && !SDL_strncasecmp(p, "[touch]", 7);
            continue;
        }
        const char *eq = memchr(p, '=', n);
        if (!in_section || !eq) {
            continue;
        }
        const char *name = p;
        size_t name_len = eq - p;
        const char *value = eq + 1;
        size_t value_len = p + n - value;
        kt_trim(&name, &name_len);
        kt_trim(&value, &value_len);
        bool keys_value = kt_is_keys_setting(name, name_len);

        size_t max = KT_MAX_FILE_SIZE;
        size_t start = len;
        if (len) {
            spec[len++] = ',';
        }
        len = kt_append_words(spec, len, max, name, name_len, '/');
        if (len < max) {
            spec[len++] = '=';
        }
        len = kt_append_words(spec, len, max, value, value_len,
                              keys_value ? '/' : ':');
        if (len >= max) {
            // Too long: the line is left out
            len = start;
            break;
        }
    }
    fclose(f);
    spec[len] = '\0';
    return spec;
}

void
sc_keyboard_touch_init_file(struct sc_keyboard_touch *kt, const char *path) {
    char *spec = kt_spec_from_file(path);
    sc_keyboard_touch_init(kt, spec ? spec : "");
    free(spec);
}

static const struct {
    const char *name;
    uint32_t button;
} kt_mouse_names[] = {
    {"Mouse_Left", SC_MOUSE_BUTTON_LEFT},
    {"Mouse_Right", SC_MOUSE_BUTTON_RIGHT},
    {"Mouse_Middle", SC_MOUSE_BUTTON_MIDDLE},
    {"Mouse_X1", SC_MOUSE_BUTTON_X1},
    {"Mouse_X2", SC_MOUSE_BUTTON_X2},
};

void
sc_keyboard_touch_key_name(const struct sc_keyboard_touch_key *key,
                           bool with_spaces, char *buf, size_t size) {
    const char *name = "?";
    if (key->input == SC_KEYBOARD_GAMEPAD_INPUT_KEY) {
        const char *sdl = SDL_GetScancodeName((SDL_Scancode) key->code);
        if (sdl && *sdl) {
            name = sdl;
        }
    } else {
        for (size_t i = 0; i < ARRAY_LEN(kt_mouse_names); ++i) {
            if (kt_mouse_names[i].button == key->code) {
                name = kt_mouse_names[i].name;
            }
        }
    }
    size_t i = 0;
    for (; name[i] && i + 1 < size; ++i) {
        char c = name[i];
        if (with_spaces && c == '_') {
            c = ' ';
        } else if (!with_spaces && c == ' ') {
            c = '_';
        }
        buf[i] = c;
    }
    if (size) {
        buf[i] = '\0';
    }
}

// A number with three decimals, whatever the locale
static void
kt_write_decimal(FILE *f, float v) {
    int32_t thousandths = (int32_t) (v * 1000 + 0.5f);
    fprintf(f, " %d.%03d", thousandths / 1000, thousandths % 1000);
}

static void
kt_write_fraction(FILE *f, float v) {
    kt_write_decimal(f, v < 0 ? 0 : v > 1 ? 1 : v);
}

static void
kt_write_keys(FILE *f, const struct sc_keyboard_touch *kt, int target) {
    bool first = true;
    for (size_t i = 0; i < kt->key_count; ++i) {
        if (kt->keys[i].target == target) {
            char name[64];
            sc_keyboard_touch_key_name(&kt->keys[i], false, name,
                                       sizeof(name));
            fprintf(f, "%s%s", first ? "" : " ", name);
            first = false;
        }
    }
}

static void
kt_write_point(FILE *f, const char *name,
               const struct sc_keyboard_touch_point *p, bool with_radius) {
    fprintf(f, "%s =", name);
    kt_write_fraction(f, p->x);
    kt_write_fraction(f, p->y);
    if (with_radius) {
        kt_write_fraction(f, p->r);
    }
    fputc('\n', f);
}

bool
sc_keyboard_touch_save(const struct sc_keyboard_touch *kt, const char *path) {
    size_t len = strlen(path);
    char *tmp = malloc(len + 5);
    if (!tmp) {
        LOG_OOM();
        return false;
    }
    memcpy(tmp, path, len);
    memcpy(tmp + len, ".tmp", 5);

    FILE *f = fopen(tmp, "w");
    if (!f) {
        LOGE("Touch keys: could not write %s: %s", tmp, strerror(errno));
        free(tmp);
        return false;
    }
    fputs("# Touch controls of this game: while one of a line's keys is held, "
          "a finger\n"
          "# touches the display at X Y, fractions of its width and height "
          "(0 0 is the\n"
          "# top left corner, 1 1 the bottom right one). Keys are SDL's key "
          "names, with\n"
          "# _ for a space, separated by spaces. The Touch Controls tab of "
          "the game's\n"
          "# Startup Options edits them, and MOD+t in the game's window.\n"
          "\n"
          "[touch]\n", f);
    if (kt->aspect > 0) {
        fputs("aspect =", f);
        kt_write_decimal(f, kt->aspect);
        fputc('\n', f);
    }
    bool casts = false;
    for (size_t t = 0; t < kt->tap_count; ++t) {
        kt_write_keys(f, kt, (int) t);
        fputs(" =", f);
        kt_write_fraction(f, kt->taps[t].x);
        kt_write_fraction(f, kt->taps[t].y);
        if (kt->kinds[t] == SC_KEYBOARD_TOUCH_CAST) {
            fputs(" cast", f);
            kt_write_fraction(f, kt->taps[t].r);
            casts = true;
        }
        fputc('\n', f);
    }
    if (casts) {
        kt_write_point(f, "cast_center", &kt->cast_center, false);
    }
    if (kt->has_joystick) {
        kt_write_point(f, "joystick", &kt->joystick, true);
        for (size_t i = 0; i < ARRAY_LEN(kt_joystick_keys); ++i) {
            fprintf(f, "%s = ", kt_joystick_keys[i].name);
            kt_write_keys(f, kt, kt_joystick_keys[i].target);
            fputc('\n', f);
        }
        fprintf(f, "joystick_ramp_ms = %" PRIu32 "\n"
                   "joystick_walk_percent = %" PRIu32 "\n"
                   "joystick_sprint_percent = %" PRIu32 "\n",
                kt->joystick_ramp_ms, kt->joystick_walk_percent,
                kt->joystick_sprint_percent);
    }
    if (kt->has_aim) {
        kt_write_point(f, "aim", &kt->aim, true);
        fprintf(f, "aim_sensitivity = %" PRIu32 "\n", kt->aim_sensitivity);
    }

    bool ok = !ferror(f);
    ok = !fclose(f) && ok;
    if (ok && rename(tmp, path)) {
        LOGE("Touch keys: could not write %s: %s", path, strerror(errno));
        ok = false;
    } else if (!ok) {
        LOGE("Touch keys: could not write %s", tmp);
    }
    if (!ok) {
        remove(tmp);
    }
    free(tmp);
    return ok;
}

// Where the layout's points are on the display

// How a coordinate placed at a fraction f of a side, of length ref (in units
// of the other side) moves on a side of length cur: anchored to the near
// edge, or to the middle
static float
kt_anchor(float f, float ref, float cur) {
    float u = f * ref;
    if (f < 1.f / 3) {
        return u;
    }
    if (f > 2.f / 3) {
        return cur - (ref - u);
    }
    return cur / 2 + (u - ref / 2);
}

static bool
kt_same_aspect(float a, float b) {
    return fabsf(a - b) <= 0.005f * b;
}

float
sc_keyboard_touch_px_x(const struct sc_keyboard_touch *kt,
                       const struct sc_keyboard_touch_point *p,
                       struct sc_size size) {
    float w = size.width;
    float h = size.height;
    if (kt->aspect > 0 && h && w > h && kt->aspect > 1
            && !kt_same_aspect(w / h, kt->aspect)) {
        // Landscape at both: measured in display heights
        return kt_anchor(p->x, kt->aspect, w / h) * h;
    }
    return p->x * w;
}

float
sc_keyboard_touch_px_y(const struct sc_keyboard_touch *kt,
                       const struct sc_keyboard_touch_point *p,
                       struct sc_size size) {
    float w = size.width;
    float h = size.height;
    if (kt->aspect > 0 && w && h > w && kt->aspect < 1
            && !kt_same_aspect(w / h, kt->aspect)) {
        // Portrait at both: measured in display widths
        return kt_anchor(p->y, 1 / kt->aspect, h / w) * w;
    }
    return p->y * h;
}

static struct sc_size
kt_size(const struct sc_keyboard_touch *kt) {
    return kt->sink->get_size(kt->sink->userdata);
}

static int32_t
kt_round(float v) {
    return (int32_t) (v < 0 ? v - 0.5f : v + 0.5f);
}

// Sends a finger's event, unless it would be one finger too many or it is
// about a finger that is not down: then nothing happens, and later events
// for that finger, its release included, are dropped too
static void
kt_touch(struct sc_keyboard_touch *kt, enum android_motionevent_action action,
         uint64_t pointer_id, float x, float y) {
    unsigned bit = (unsigned) (pointer_id - SC_KEYBOARD_TOUCH_POINTER_ID);
    assert(bit < SC_KEYBOARD_TOUCH_FINGER_COUNT);
    uint64_t mask = UINT64_C(1) << bit;
    if (action == AMOTION_EVENT_ACTION_DOWN) {
        if (kt->fingers_down & mask) {
            return;
        }
        if (__builtin_popcountll(kt->fingers_down)
                >= SC_KEYBOARD_TOUCH_MAX_FINGERS) {
            if (!kt->told_too_many) {
                LOGW("Touch keys: Android takes %d fingers at once; a key "
                     "touched nothing", SC_KEYBOARD_TOUCH_MAX_FINGERS);
                kt->told_too_many = true;
            }
            return;
        }
        kt->fingers_down |= mask;
    } else {
        if (!(kt->fingers_down & mask)) {
            return;
        }
        if (action == AMOTION_EVENT_ACTION_UP) {
            kt->fingers_down &= ~mask;
        }
    }

    struct sc_size size = kt_size(kt);
    // Keep the finger on the display
    float max_x = size.width ? size.width - 1 : 0;
    float max_y = size.height ? size.height - 1 : 0;
    x = x < 0 ? 0 : x > max_x ? max_x : x;
    y = y < 0 ? 0 : y > max_y ? max_y : y;
    struct sc_point point = {kt_round(x), kt_round(y)};
    kt->sink->touch(kt->sink->userdata, action, pointer_id, point);
}

static bool
kt_is_down(const struct sc_keyboard_touch *kt, uint64_t pointer_id) {
    return kt->fingers_down
         & (UINT64_C(1) << (pointer_id - SC_KEYBOARD_TOUCH_POINTER_ID));
}

// Taps and skill casts

// Where a tap's finger goes: its point, or for a skill cast, toward the
// pointer
static struct sc_point
kt_tap_target(const struct sc_keyboard_touch *kt, size_t index) {
    struct sc_size size = kt_size(kt);
    const struct sc_keyboard_touch_point *tap = &kt->taps[index];
    float x = sc_keyboard_touch_px_x(kt, tap, size);
    float y = sc_keyboard_touch_px_y(kt, tap, size);
    if (kt->kinds[index] == SC_KEYBOARD_TOUCH_CAST && kt->has_cursor
            && size.height) {
        float full = KT_CAST_FULL * size.height;
        float vx = (kt->cursor_x
                    - sc_keyboard_touch_px_x(kt, &kt->cast_center, size)) / full;
        float vy = (kt->cursor_y
                    - sc_keyboard_touch_px_y(kt, &kt->cast_center, size)) / full;
        float len = sqrtf(vx * vx + vy * vy);
        if (len > 1) {
            vx /= len;
            vy /= len;
        }
        float r = tap->r * size.height;
        x += vx * r;
        y += vy * r;
    }
    return (struct sc_point) {kt_round(x), kt_round(y)};
}

static void
kt_tap_down(struct sc_keyboard_touch *kt, size_t index) {
    struct sc_size size = kt_size(kt);
    const struct sc_keyboard_touch_point *tap = &kt->taps[index];
    uint64_t id = SC_KEYBOARD_TOUCH_POINTER_ID + index;
    float x = sc_keyboard_touch_px_x(kt, tap, size);
    float y = sc_keyboard_touch_px_y(kt, tap, size);
    kt_touch(kt, AMOTION_EVENT_ACTION_DOWN, id, x, y);
    kt->tap_at[index] = (struct sc_point) {kt_round(x), kt_round(y)};
    if (kt->kinds[index] == SC_KEYBOARD_TOUCH_CAST) {
        struct sc_point target = kt_tap_target(kt, index);
        if (target.x != kt->tap_at[index].x
                || target.y != kt->tap_at[index].y) {
            kt_touch(kt, AMOTION_EVENT_ACTION_MOVE, id, target.x, target.y);
            kt->tap_at[index] = target;
        }
    }
}

static void
kt_tap_up(struct sc_keyboard_touch *kt, size_t index) {
    kt_touch(kt, AMOTION_EVENT_ACTION_UP, SC_KEYBOARD_TOUCH_POINTER_ID + index,
             kt->tap_at[index].x, kt->tap_at[index].y);
}

void
sc_keyboard_touch_set_cursor(struct sc_keyboard_touch *kt, bool has, float x,
                             float y) {
    kt->has_cursor = has;
    kt->cursor_x = x;
    kt->cursor_y = y;
    if (!has) {
        return;
    }
    for (size_t i = 0; i < kt->tap_count; ++i) {
        if (kt->kinds[i] != SC_KEYBOARD_TOUCH_CAST || !kt->tap_held[i]) {
            continue;
        }
        struct sc_point target = kt_tap_target(kt, i);
        if (target.x != kt->tap_at[i].x || target.y != kt->tap_at[i].y) {
            kt_touch(kt, AMOTION_EVENT_ACTION_MOVE,
                     SC_KEYBOARD_TOUCH_POINTER_ID + i, target.x, target.y);
            kt->tap_at[i] = target;
        }
    }
}

// The joystick

// Of two opposite targets, the last pressed held: -1, 1, or 0 for none
static int
kt_axis(const struct sc_keyboard_touch *kt, int16_t negative,
        int16_t positive) {
    uint32_t neg = 0;
    uint32_t pos = 0;
    for (size_t i = 0; i < kt->key_count; ++i) {
        const struct sc_keyboard_touch_key *key = &kt->keys[i];
        if (key->target == negative && key->pressed > neg) {
            neg = key->pressed;
        } else if (key->target == positive && key->pressed > pos) {
            pos = key->pressed;
        }
    }
    if (!neg && !pos) {
        return 0;
    }
    return neg > pos ? -1 : 1;
}

static bool
kt_target_held(const struct sc_keyboard_touch *kt, int16_t target) {
    for (size_t i = 0; i < kt->key_count; ++i) {
        if (kt->keys[i].target == target && kt->keys[i].pressed) {
            return true;
        }
    }
    return false;
}

static void
kt_update_joystick(struct sc_keyboard_touch *kt, uint64_t now_ms) {
    int x = kt_axis(kt, KT_JOYSTICK_LEFT, KT_JOYSTICK_RIGHT);
    int y = kt_axis(kt, KT_JOYSTICK_UP, KT_JOYSTICK_DOWN);
    if (!x && !y) {
        if (kt->joystick_down) {
            kt_touch(kt, AMOTION_EVENT_ACTION_UP,
                     SC_KEYBOARD_TOUCH_JOYSTICK_POINTER_ID,
                     kt->joystick_at.x, kt->joystick_at.y);
            kt->joystick_down = false;
        }
        kt->joystick_ramping = false;
        return;
    }

    struct sc_size size = kt_size(kt);
    float cx = sc_keyboard_touch_px_x(kt, &kt->joystick, size);
    float cy = sc_keyboard_touch_px_y(kt, &kt->joystick, size);
    // The sprint key wins over the walk key
    uint32_t percent = kt_target_held(kt, KT_JOYSTICK_SPRINT)
                     ? kt->joystick_sprint_percent
                     : kt_target_held(kt, KT_JOYSTICK_WALK)
                     ? kt->joystick_walk_percent : 100;
    float r = kt->joystick.r * size.height * percent / 100;
    float dx = x;
    float dy = y;
    if (x && y) {
        dx *= KT_DIAGONAL;
        dy *= KT_DIAGONAL;
    }

    if (!kt->joystick_down) {
        kt_touch(kt, AMOTION_EVENT_ACTION_DOWN,
                 SC_KEYBOARD_TOUCH_JOYSTICK_POINTER_ID, cx, cy);
        if (!kt_is_down(kt, SC_KEYBOARD_TOUCH_JOYSTICK_POINTER_ID)) {
            return;
        }
        kt->joystick_down = true;
        kt->joystick_at = (struct sc_point) {kt_round(cx), kt_round(cy)};
        // As a thumb does, from the center, over the ramp
        kt->joystick_ramping = kt->joystick_ramp_ms && kt->timer;
        kt->joystick_start_ms = now_ms;
        if (kt->joystick_ramping) {
            kt->timer->arm(kt->timer->userdata);
        }
    }

    float f = 1;
    if (kt->joystick_ramping) {
        f = (float) (now_ms - kt->joystick_start_ms) / kt->joystick_ramp_ms;
        if (f < KT_RAMP_FIRST_STEP) {
            f = KT_RAMP_FIRST_STEP;
        }
        if (f >= 1) {
            f = 1;
            kt->joystick_ramping = false;
        }
    }
    struct sc_point at = {kt_round(cx + dx * r * f),
                          kt_round(cy + dy * r * f)};
    if (at.x != kt->joystick_at.x || at.y != kt->joystick_at.y) {
        kt_touch(kt, AMOTION_EVENT_ACTION_MOVE,
                 SC_KEYBOARD_TOUCH_JOYSTICK_POINTER_ID, at.x, at.y);
        kt->joystick_at = at;
    }
}

bool
sc_keyboard_touch_tick(struct sc_keyboard_touch *kt, uint64_t now_ms) {
    kt->now_ms = now_ms;
    if (kt->joystick_ramping) {
        kt_update_joystick(kt, now_ms);
    }
    return kt->joystick_ramping;
}

static void
kt_apply_key(struct sc_keyboard_touch *kt, struct sc_keyboard_touch_key *key,
             bool down, uint64_t now_ms) {
    key->pressed = down ? ++kt->press_count : 0;
    if (key->target >= 0) {
        size_t index = (size_t) key->target;
        assert(index < kt->tap_count);
        if (down) {
            if (kt->tap_held[index]++ == 0) {
                kt_tap_down(kt, index);
            }
        } else {
            assert(kt->tap_held[index]);
            if (--kt->tap_held[index] == 0) {
                kt_tap_up(kt, index);
            }
        }
    } else if (kt->has_joystick) {
        kt_update_joystick(kt, now_ms);
    }
}

bool
sc_keyboard_touch_handle_key(struct sc_keyboard_touch *kt,
                             const SDL_KeyboardEvent *event) {
    struct sc_keyboard_touch_key *key =
        kt_find_key(kt, SC_KEYBOARD_GAMEPAD_INPUT_KEY, event->scancode);
    if (!key) {
        return false;
    }

    uint64_t now_ms = event->timestamp / 1000000;
    kt->now_ms = now_ms;
    bool down = event->type == SDL_EVENT_KEY_DOWN;
    if (!down) {
        // A held key is released whatever modifier is down by now; the
        // release of a key that typed (pressed with a modifier) types too
        if (!key->pressed) {
            return false;
        }
        kt_apply_key(kt, key, false, now_ms);
        return true;
    }

    if (event->repeat) {
        // A held key keeps its finger down by itself; the repeats of a key
        // that typed keep typing
        return key->pressed;
    }

    // A shortcut (MOD+key, or the MOD key itself) is not a touch
    if (event->mod & kt->shortcut_mods) {
        return false;
    }

    if (!key->pressed) {
        kt_apply_key(kt, key, true, now_ms);
    }
    return true;
}

// The aim

bool
sc_keyboard_touch_takes_mouse(const struct sc_keyboard_touch *kt) {
    return kt->has_aim;
}

static uint64_t
kt_aim_id(const struct sc_keyboard_touch *kt, unsigned finger) {
    (void) kt;
    return SC_KEYBOARD_TOUCH_AIM_POINTER_ID + finger;
}

void
sc_keyboard_touch_handle_mouse_motion(struct sc_keyboard_touch *kt,
                                      float xrel, float yrel) {
    if (!kt->has_aim || (!xrel && !yrel)) {
        return;
    }

    struct sc_size size = kt_size(kt);
    float cx = sc_keyboard_touch_px_x(kt, &kt->aim, size);
    float cy = sc_keyboard_touch_px_y(kt, &kt->aim, size);
    float r = kt->aim.r * size.height;
    float k = kt->aim_sensitivity / 100.f;
    float dx = xrel * k;
    float dy = yrel * k;

    if (!kt->aim_down) {
        kt_touch(kt, AMOTION_EVENT_ACTION_DOWN,
                 kt_aim_id(kt, kt->aim_finger), cx, cy);
        if (!kt_is_down(kt, kt_aim_id(kt, kt->aim_finger))) {
            return;
        }
        kt->aim_down = true;
        kt->aim_x = cx;
        kt->aim_y = cy;
    }

    for (int i = 0; i < KT_AIM_MAX_HANDOFFS && (dx || dy); ++i) {
        float px = kt->aim_x - cx;
        float py = kt->aim_y - cy;
        float nx = px + dx;
        float ny = py + dy;
        if (nx * nx + ny * ny <= r * r) {
            kt_touch(kt, AMOTION_EVENT_ACTION_MOVE,
                     kt_aim_id(kt, kt->aim_finger), cx + nx, cy + ny);
            kt->aim_x = cx + nx;
            kt->aim_y = cy + ny;
            return;
        }

        // The finger reaches the edge of the aim's circle at t of the motion
        float a = dx * dx + dy * dy;
        float b = 2 * (px * dx + py * dy);
        float c = px * px + py * py - r * r;
        float t = 0;
        if (c < 0) {
            t = (-b + sqrtf(b * b - 4 * a * c)) / (2 * a);
            t = t < 0 ? 0 : t > 1 ? 1 : t;
        }
        if (t > 0) {
            kt->aim_x += t * dx;
            kt->aim_y += t * dy;
            kt_touch(kt, AMOTION_EVENT_ACTION_MOVE,
                     kt_aim_id(kt, kt->aim_finger), kt->aim_x, kt->aim_y);
        }

        // The other finger touches the center before this one lifts, so that
        // there is always a finger on the view, and takes the rest
        unsigned old = kt->aim_finger;
        unsigned next = 1 - old;
        kt_touch(kt, AMOTION_EVENT_ACTION_DOWN, kt_aim_id(kt, next), cx, cy);
        kt_touch(kt, AMOTION_EVENT_ACTION_UP, kt_aim_id(kt, old), kt->aim_x,
                 kt->aim_y);
        kt->aim_finger = next;
        kt->aim_x = cx;
        kt->aim_y = cy;
        if (!kt_is_down(kt, kt_aim_id(kt, next))) {
            kt->aim_down = false;
            return;
        }
        dx *= 1 - t;
        dy *= 1 - t;
    }
}

bool
sc_keyboard_touch_handle_mouse_button(struct sc_keyboard_touch *kt,
                                      uint32_t button, bool down,
                                      bool captured) {
    struct sc_keyboard_touch_key *key =
        kt_find_key(kt, SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON, button);
    if (!down) {
        if (!key || !key->pressed) {
            return false;
        }
        kt_apply_key(kt, key, false, kt->now_ms);
        return true;
    }
    if (!captured && (!key || button == SC_MOUSE_BUTTON_LEFT)) {
        // The free mouse: the left button is the mouse's own finger
        return false;
    }
    if (key && !key->pressed) {
        kt_apply_key(kt, key, true, kt->now_ms);
    }
    // Captured, an unmapped button is dropped
    return true;
}

static void
kt_lift_aim(struct sc_keyboard_touch *kt) {
    if (kt->aim_down) {
        kt_touch(kt, AMOTION_EVENT_ACTION_UP, kt_aim_id(kt, kt->aim_finger),
                 kt->aim_x, kt->aim_y);
        kt->aim_down = false;
    }
}

void
sc_keyboard_touch_release_all(struct sc_keyboard_touch *kt) {
    for (size_t i = 0; i < kt->key_count; ++i) {
        if (kt->keys[i].pressed) {
            kt_apply_key(kt, &kt->keys[i], false, kt->now_ms);
        }
    }
    kt_lift_aim(kt);
    kt->joystick_ramping = false;
}

void
sc_keyboard_touch_release_mouse(struct sc_keyboard_touch *kt) {
    for (size_t i = 0; i < kt->key_count; ++i) {
        struct sc_keyboard_touch_key *key = &kt->keys[i];
        if (key->pressed && key->input != SC_KEYBOARD_GAMEPAD_INPUT_KEY) {
            kt_apply_key(kt, key, false, kt->now_ms);
        }
    }
    kt_lift_aim(kt);
}

// Editing

void
sc_keyboard_touch_rebase(struct sc_keyboard_touch *kt, struct sc_size size) {
    assert(!kt->fingers_down);
    if (!size.width || !size.height) {
        return;
    }
    struct sc_keyboard_touch_point *points[SC_KEYBOARD_TOUCH_MAX_TAPS + 3];
    size_t n = 0;
    for (size_t i = 0; i < kt->tap_count; ++i) {
        points[n++] = &kt->taps[i];
    }
    points[n++] = &kt->joystick;
    points[n++] = &kt->aim;
    points[n++] = &kt->cast_center;
    for (size_t i = 0; i < n; ++i) {
        float x = sc_keyboard_touch_px_x(kt, points[i], size) / size.width;
        float y = sc_keyboard_touch_px_y(kt, points[i], size) / size.height;
        points[i]->x = x < 0 ? 0 : x > 1 ? 1 : x;
        points[i]->y = y < 0 ? 0 : y > 1 ? 1 : y;
    }
    kt->aspect = (float) size.width / size.height;
}

static void
kt_remove_key_at(struct sc_keyboard_touch *kt, size_t i) {
    assert(i < kt->key_count);
    memmove(&kt->keys[i], &kt->keys[i + 1],
            (kt->key_count - i - 1) * sizeof(kt->keys[0]));
    kt->key_count--;
}

int
sc_keyboard_touch_add_tap(struct sc_keyboard_touch *kt, float x, float y) {
    if (kt->tap_count == SC_KEYBOARD_TOUCH_MAX_TAPS) {
        return -1;
    }
    size_t index = kt->tap_count++;
    kt->taps[index] = (struct sc_keyboard_touch_point) {x, y, 0};
    kt->kinds[index] = SC_KEYBOARD_TOUCH_TAP;
    kt->tap_held[index] = 0;
    return (int) index;
}

void
sc_keyboard_touch_remove_tap(struct sc_keyboard_touch *kt, size_t index) {
    assert(index < kt->tap_count);
    assert(!kt->tap_held[index]);
    for (size_t i = kt->key_count; i-- > 0;) {
        if (kt->keys[i].target == (int16_t) index) {
            kt_remove_key_at(kt, i);
        } else if (kt->keys[i].target > (int16_t) index) {
            kt->keys[i].target--;
        }
    }
    size_t tail = kt->tap_count - index - 1;
    memmove(&kt->taps[index], &kt->taps[index + 1], tail * sizeof(kt->taps[0]));
    memmove(&kt->kinds[index], &kt->kinds[index + 1],
            tail * sizeof(kt->kinds[0]));
    memmove(&kt->tap_held[index], &kt->tap_held[index + 1],
            tail * sizeof(kt->tap_held[0]));
    memmove(&kt->tap_at[index], &kt->tap_at[index + 1],
            tail * sizeof(kt->tap_at[0]));
    kt->tap_count--;
}

int
sc_keyboard_touch_bind(struct sc_keyboard_touch *kt,
                       enum sc_keyboard_gamepad_input input, uint32_t code,
                       int target) {
    struct sc_keyboard_touch_key *key = kt_find_key(kt, input, code);
    if (key) {
        assert(!key->pressed);
        int old = key->target;
        kt_remove_key_at(kt, key - kt->keys);
        if (old == target) {
            // Taken from it
            return target;
        }
        if (old >= 0 && !kt_has_target_key(kt, old)) {
            sc_keyboard_touch_remove_tap(kt, (size_t) old);
            if (target > old) {
                target--;
            }
        }
    }
    if (kt->key_count == SC_KEYBOARD_TOUCH_MAX_KEYS) {
        return -1;
    }
    kt->keys[kt->key_count++] = (struct sc_keyboard_touch_key) {
        .input = input,
        .code = code,
        .target = (int16_t) target,
        .pressed = 0,
    };
    return target;
}

void
sc_keyboard_touch_prune(struct sc_keyboard_touch *kt) {
    for (size_t i = kt->tap_count; i-- > 0;) {
        if (!kt_has_target_key(kt, (int) i)) {
            sc_keyboard_touch_remove_tap(kt, i);
        }
    }
}

void
sc_keyboard_touch_set_joystick(struct sc_keyboard_touch *kt, bool set,
                               float x, float y, float r) {
    assert(!kt->joystick_down);
    if (set) {
        kt->joystick = (struct sc_keyboard_touch_point) {x, y, r};
        if (!kt->has_joystick) {
            kt->has_joystick = true;
            kt_add_default_joystick_keys(kt);
        }
        return;
    }
    kt->has_joystick = false;
    for (size_t i = kt->key_count; i-- > 0;) {
        if (kt->keys[i].target < 0) {
            kt_remove_key_at(kt, i);
        }
    }
}

void
sc_keyboard_touch_set_aim(struct sc_keyboard_touch *kt, bool set, float x,
                          float y, float r) {
    assert(!kt->aim_down);
    kt->has_aim = set;
    if (set) {
        kt->aim = (struct sc_keyboard_touch_point) {x, y, r};
    }
}
