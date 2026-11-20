#include "touch_editor.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "input_events.h"
#include "util/log.h"

// Sizes in window points
#define TE_TAP_RADIUS 22.f
#define TE_HANDLE_RADIUS 12.f
#define TE_RING_GRAB 8.f
#define TE_PADDING 6.f
// The help line at the bottom, broken into at most this many lines
#define TE_HINT_MAX_LINES 4
#define TE_CIRCLE_SEGMENTS 40

// The radius of a ring, as a fraction of the display's height
#define TE_MIN_RADIUS 0.02f
#define TE_MAX_RADIUS 0.5f

#define TE_MIN_SENSITIVITY 10
#define TE_MAX_SENSITIVITY 1000

enum te_button {
    TE_BUTTON_JOYSTICK,
    TE_BUTTON_AIM,
    TE_BUTTON_CAST,
    TE_BUTTON_LEFT_CLICK,
    TE_BUTTON_DELETE,
    TE_BUTTON_DONE,
};

static_assert(TE_BUTTON_DONE + 1 == SC_TOUCH_EDITOR_BUTTON_COUNT,
              "one rectangle per button");

static const char *const te_button_labels[] = {
    "Joystick", "Mouse aim", "Skill cast", "Left click", "Delete", "Done",
};

// A skill cast's reach when a point becomes one
#define TE_DEFAULT_CAST_RADIUS 0.10f

static const int te_directions[] = {
    SC_KEYBOARD_TOUCH_JOYSTICK_UP,
    SC_KEYBOARD_TOUCH_JOYSTICK_DOWN,
    SC_KEYBOARD_TOUCH_JOYSTICK_LEFT,
    SC_KEYBOARD_TOUCH_JOYSTICK_RIGHT,
    SC_KEYBOARD_TOUCH_JOYSTICK_WALK,
    SC_KEYBOARD_TOUCH_JOYSTICK_SPRINT,
};

#define TE_JOYSTICK_TARGETS ARRAY_LEN(te_directions)

static const char *const te_direction_names[] = {"up", "down", "left",
                                                 "right", "walk", "sprint"};

void
sc_touch_editor_init(struct sc_touch_editor *te, struct sc_keyboard_touch *kt,
                     const char *path) {
    memset(te, 0, sizeof(*te));
    te->kt = kt;
    te->path = path;
    te->density = 1;
}

void
sc_touch_editor_open(struct sc_touch_editor *te, struct sc_size device) {
    // The points as they are shown on this display, at its aspect ratio
    sc_keyboard_touch_rebase(te->kt, device);
    te->device = device;
    te->active = true;
    te->changed = false;
    te->selection = SC_TOUCH_EDITOR_SELECTION_NONE;
    te->drag = SC_TOUCH_EDITOR_DRAG_NONE;
    te->direction = 0;
    te->has_buttons = false;
    te->close_requested = false;
    LOGI("Touch controls: editing (MOD+t or Done to save)");
}

bool
sc_touch_editor_close(struct sc_touch_editor *te) {
    assert(te->active);
    te->active = false;
    size_t taps = te->kt->tap_count;
    sc_keyboard_touch_prune(te->kt);
    if (!te->changed && taps == te->kt->tap_count) {
        LOGI("Touch controls: unchanged");
        return true;
    }
    if (!sc_keyboard_touch_save(te->kt, te->path)) {
        return false;
    }
    LOGI("Touch controls: saved to %s", te->path);
    return true;
}

void
sc_touch_editor_set_view(struct sc_touch_editor *te, SDL_FRect view,
                         float density, struct sc_size device) {
    te->view = view;
    te->density = density > 0 ? density : 1;
    if (te->active && device.width && device.height
            && (device.width != te->device.width
                || device.height != te->device.height)) {
        // The window was resized: the points move as they do for the game
        sc_keyboard_touch_rebase(te->kt, device);
    }
    te->device = device;
}

// Window points from the display's fractions, and back

static float
te_x(const struct sc_touch_editor *te, float fx) {
    return te->view.x + fx * te->view.w;
}

static float
te_y(const struct sc_touch_editor *te, float fy) {
    return te->view.y + fy * te->view.h;
}

static float
te_r(const struct sc_touch_editor *te, float fr) {
    return fr * te->view.h;
}

static float
te_clamp(float v, float min, float max) {
    return v < min ? min : v > max ? max : v;
}

static float
te_fx(const struct sc_touch_editor *te, float x) {
    return te->view.w ? te_clamp((x - te->view.x) / te->view.w, 0, 1) : 0;
}

static float
te_fy(const struct sc_touch_editor *te, float y) {
    return te->view.h ? te_clamp((y - te->view.y) / te->view.h, 0, 1) : 0;
}

static bool
te_in_rect(const SDL_FRect *r, float x, float y) {
    return x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h;
}

static bool
te_tap_has_keys(const struct sc_keyboard_touch *kt, int tap) {
    for (size_t i = 0; i < kt->key_count; ++i) {
        if (kt->keys[i].target == tap) {
            return true;
        }
    }
    return false;
}

// Selects (kind, tap); a tap left without a key as the selection moves away
// is removed
static void
te_select(struct sc_touch_editor *te, enum sc_touch_editor_selection kind,
          int tap) {
    if (te->selection == SC_TOUCH_EDITOR_SELECTION_TAP
            && !(kind == SC_TOUCH_EDITOR_SELECTION_TAP && tap == te->tap)
            && !te_tap_has_keys(te->kt, te->tap)) {
        sc_keyboard_touch_remove_tap(te->kt, (size_t) te->tap);
        if (kind == SC_TOUCH_EDITOR_SELECTION_TAP && tap > te->tap) {
            --tap;
        }
    }
    if (kind == SC_TOUCH_EDITOR_SELECTION_JOYSTICK
            && te->selection != SC_TOUCH_EDITOR_SELECTION_JOYSTICK) {
        te->direction = 0;
    }
    te->selection = kind;
    te->tap = tap;
}

static void
te_delete_selection(struct sc_touch_editor *te) {
    struct sc_keyboard_touch *kt = te->kt;
    switch (te->selection) {
        case SC_TOUCH_EDITOR_SELECTION_TAP:
            sc_keyboard_touch_remove_tap(kt, (size_t) te->tap);
            break;
        case SC_TOUCH_EDITOR_SELECTION_JOYSTICK:
            sc_keyboard_touch_set_joystick(kt, false, 0, 0, 0);
            break;
        case SC_TOUCH_EDITOR_SELECTION_AIM:
            sc_keyboard_touch_set_aim(kt, false, 0, 0, 0);
            break;
        default:
            return;
    }
    te->selection = SC_TOUCH_EDITOR_SELECTION_NONE;
    te->changed = true;
}

// Gives the key (input, code) to the selected tap or joystick direction
static void
te_bind(struct sc_touch_editor *te, enum sc_keyboard_gamepad_input input,
        uint32_t code) {
    if (te->selection == SC_TOUCH_EDITOR_SELECTION_TAP) {
        int tap = sc_keyboard_touch_bind(te->kt, input, code, te->tap);
        if (tap >= 0) {
            te->tap = tap;
        } else {
            LOGW("Touch controls: too many keys");
        }
        te->changed = true;
    } else if (te->selection == SC_TOUCH_EDITOR_SELECTION_JOYSTICK) {
        int target = te_directions[te->direction];
        // A key given to a direction replaces the direction's keys
        for (size_t i = te->kt->key_count; i-- > 0;) {
            const struct sc_keyboard_touch_key *key = &te->kt->keys[i];
            if (key->target == target
                    && !(key->input == input && key->code == code)) {
                sc_keyboard_touch_bind(te->kt, key->input, key->code, target);
            }
        }
        bool has = false;
        for (size_t i = 0; i < te->kt->key_count; ++i) {
            const struct sc_keyboard_touch_key *key = &te->kt->keys[i];
            has |= key->input == input && key->code == code
                && key->target == target;
        }
        if (!has) {
            sc_keyboard_touch_bind(te->kt, input, code, target);
        }
        te->direction = (te->direction + 1) % (int) TE_JOYSTICK_TARGETS;
        te->changed = true;
    }
}

static void
te_press_button(struct sc_touch_editor *te, enum te_button button) {
    struct sc_keyboard_touch *kt = te->kt;
    switch (button) {
        case TE_BUTTON_JOYSTICK:
            if (!kt->has_joystick) {
                sc_keyboard_touch_set_joystick(kt, true, 0.15f, 0.70f, 0.12f);
                te->changed = true;
            }
            te_select(te, SC_TOUCH_EDITOR_SELECTION_JOYSTICK, 0);
            break;
        case TE_BUTTON_AIM:
            if (!kt->has_aim) {
                sc_keyboard_touch_set_aim(kt, true, 0.70f, 0.45f, 0.15f);
                te->changed = true;
            }
            te_select(te, SC_TOUCH_EDITOR_SELECTION_AIM, 0);
            break;
        case TE_BUTTON_CAST:
            if (te->selection == SC_TOUCH_EDITOR_SELECTION_TAP) {
                // A skill cast, or a tap again
                enum sc_keyboard_touch_kind *kind = &kt->kinds[te->tap];
                if (*kind == SC_KEYBOARD_TOUCH_CAST) {
                    *kind = SC_KEYBOARD_TOUCH_TAP;
                } else {
                    *kind = SC_KEYBOARD_TOUCH_CAST;
                    if (kt->taps[te->tap].r <= 0) {
                        kt->taps[te->tap].r = TE_DEFAULT_CAST_RADIUS;
                    }
                }
                te->changed = true;
            }
            break;
        case TE_BUTTON_LEFT_CLICK:
            if (te->selection == SC_TOUCH_EDITOR_SELECTION_TAP) {
                te_bind(te, SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON,
                        SC_MOUSE_BUTTON_LEFT);
            }
            break;
        case TE_BUTTON_DELETE:
            te_delete_selection(te);
            break;
        case TE_BUTTON_DONE:
            // The owner closes the editor, as for MOD+t, and gives the game
            // the mouse again
            te->close_requested = true;
            break;
    }
}

static bool
te_has_casts(const struct sc_keyboard_touch *kt) {
    for (size_t i = 0; i < kt->tap_count; ++i) {
        if (kt->kinds[i] == SC_KEYBOARD_TOUCH_CAST) {
            return true;
        }
    }
    return false;
}

static float
te_distance(float x1, float y1, float x2, float y2) {
    float dx = x1 - x2;
    float dy = y1 - y2;
    return sqrtf(dx * dx + dy * dy);
}

// Selects the control at (x, y) and starts dragging it; false if there is
// none
static bool
te_grab(struct sc_touch_editor *te, float x, float y) {
    struct sc_keyboard_touch *kt = te->kt;
    for (size_t i = kt->tap_count; i-- > 0;) {
        float cx = te_x(te, kt->taps[i].x);
        float cy = te_y(te, kt->taps[i].y);
        if (te_distance(x, y, cx, cy) <= TE_TAP_RADIUS) {
            te_select(te, SC_TOUCH_EDITOR_SELECTION_TAP, (int) i);
            te->drag = SC_TOUCH_EDITOR_DRAG_MOVE;
            // The tap may have moved down the list as a keyless one went
            cx = te_x(te, kt->taps[te->tap].x);
            cy = te_y(te, kt->taps[te->tap].y);
            te->drag_dx = cx - x;
            te->drag_dy = cy - y;
            return true;
        }
    }

    // The character, where skill casts aim from
    if (te_has_casts(kt)) {
        float cx = te_x(te, kt->cast_center.x);
        float cy = te_y(te, kt->cast_center.y);
        if (te_distance(x, y, cx, cy) <= TE_HANDLE_RADIUS) {
            te_select(te, SC_TOUCH_EDITOR_SELECTION_CAST_CENTER, 0);
            te->drag = SC_TOUCH_EDITOR_DRAG_MOVE;
            te->drag_dx = cx - x;
            te->drag_dy = cy - y;
            return true;
        }
    }

    // A skill cast's ring resizes its reach
    for (size_t i = kt->tap_count; i-- > 0;) {
        if (kt->kinds[i] != SC_KEYBOARD_TOUCH_CAST) {
            continue;
        }
        float d = te_distance(x, y, te_x(te, kt->taps[i].x),
                              te_y(te, kt->taps[i].y));
        if (fabsf(d - te_r(te, kt->taps[i].r)) <= TE_RING_GRAB) {
            te_select(te, SC_TOUCH_EDITOR_SELECTION_TAP, (int) i);
            te->drag = SC_TOUCH_EDITOR_DRAG_RADIUS;
            return true;
        }
    }

    struct {
        bool set;
        const struct sc_keyboard_touch_point *point;
        enum sc_touch_editor_selection kind;
    } rings[] = {
        {kt->has_aim, &kt->aim, SC_TOUCH_EDITOR_SELECTION_AIM},
        {kt->has_joystick, &kt->joystick, SC_TOUCH_EDITOR_SELECTION_JOYSTICK},
    };
    for (size_t i = 0; i < ARRAY_LEN(rings); ++i) {
        if (!rings[i].set) {
            continue;
        }
        float cx = te_x(te, rings[i].point->x);
        float cy = te_y(te, rings[i].point->y);
        float r = te_r(te, rings[i].point->r);
        float d = te_distance(x, y, cx, cy);
        if (fabsf(d - r) <= TE_RING_GRAB) {
            te_select(te, rings[i].kind, 0);
            te->drag = SC_TOUCH_EDITOR_DRAG_RADIUS;
            return true;
        }
        if (d < r) {
            te_select(te, rings[i].kind, 0);
            te->drag = SC_TOUCH_EDITOR_DRAG_MOVE;
            te->drag_dx = cx - x;
            te->drag_dy = cy - y;
            return true;
        }
    }
    return false;
}

static struct sc_keyboard_touch_point *
te_selected_point(struct sc_touch_editor *te) {
    switch (te->selection) {
        case SC_TOUCH_EDITOR_SELECTION_TAP:
            return &te->kt->taps[te->tap];
        case SC_TOUCH_EDITOR_SELECTION_JOYSTICK:
            return &te->kt->joystick;
        case SC_TOUCH_EDITOR_SELECTION_AIM:
            return &te->kt->aim;
        case SC_TOUCH_EDITOR_SELECTION_CAST_CENTER:
            return &te->kt->cast_center;
        default:
            return NULL;
    }
}

static void
te_drag_to(struct sc_touch_editor *te, float x, float y) {
    struct sc_keyboard_touch_point *point = te_selected_point(te);
    if (!point) {
        te->drag = SC_TOUCH_EDITOR_DRAG_NONE;
        return;
    }
    if (te->drag == SC_TOUCH_EDITOR_DRAG_MOVE) {
        point->x = te_fx(te, x + te->drag_dx);
        point->y = te_fy(te, y + te->drag_dy);
    } else {
        float d = te_distance(x, y, te_x(te, point->x), te_y(te, point->y));
        point->r = te->view.h
                 ? te_clamp(d / te->view.h, TE_MIN_RADIUS, TE_MAX_RADIUS)
                 : point->r;
    }
    te->changed = true;
}

// Returns the button at (x, y), or -1
static int
te_button_at(const struct sc_touch_editor *te, float x, float y) {
    if (!te->has_buttons) {
        return -1;
    }
    for (int i = 0; i < SC_TOUCH_EDITOR_BUTTON_COUNT; ++i) {
        if (te_in_rect(&te->buttons[i], x, y)) {
            return i;
        }
    }
    return -1;
}

static bool
te_handle_left_down(struct sc_touch_editor *te, float x, float y) {
    int button = te_button_at(te, x, y);
    if (button >= 0) {
        te_press_button(te, button);
        return true;
    }
    // A control drawn over the toolbar's band is grabbed all the same
    if (te_grab(te, x, y)) {
        return true;
    }
    if (te->has_buttons && te_in_rect(&te->bar, x, y)) {
        return true;
    }
    if (!te_in_rect(&te->view, x, y)) {
        te_select(te, SC_TOUCH_EDITOR_SELECTION_NONE, 0);
        return true;
    }
    // A new point, selected, to be given a key
    te_select(te, SC_TOUCH_EDITOR_SELECTION_NONE, 0);
    int tap = sc_keyboard_touch_add_tap(te->kt, te_fx(te, x), te_fy(te, y));
    if (tap < 0) {
        LOGW("Touch controls: too many points");
        return true;
    }
    te_select(te, SC_TOUCH_EDITOR_SELECTION_TAP, tap);
    te->drag = SC_TOUCH_EDITOR_DRAG_MOVE;
    te->drag_dx = 0;
    te->drag_dy = 0;
    return true;
}

static bool
te_handle_key(struct sc_touch_editor *te, const SDL_KeyboardEvent *event) {
    if (event->mod & te->shortcut_mods) {
        // A shortcut, or the shortcut modifier itself
        return false;
    }
    if (event->scancode == SDL_SCANCODE_F11) {
        // Fullscreen
        return false;
    }
    if (event->type != SDL_EVENT_KEY_DOWN || event->repeat
            || event->scancode == SDL_SCANCODE_UNKNOWN) {
        return true;
    }
    switch (event->scancode) {
        case SDL_SCANCODE_ESCAPE:
            te_select(te, SC_TOUCH_EDITOR_SELECTION_NONE, 0);
            return true;
        case SDL_SCANCODE_DELETE:
            te_delete_selection(te);
            return true;
        default:
            break;
    }
    te_bind(te, SC_KEYBOARD_GAMEPAD_INPUT_KEY, event->scancode);
    return true;
}

bool
sc_touch_editor_handle_event(struct sc_touch_editor *te,
                             const SDL_Event *event) {
    assert(te->active);
    switch (event->type) {
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
            return te_handle_key(te, &event->key);
        case SDL_EVENT_TEXT_INPUT:
            return true;
        case SDL_EVENT_MOUSE_BUTTON_DOWN: {
            const SDL_MouseButtonEvent *b = &event->button;
            if (b->which == SDL_TOUCH_MOUSEID) {
                return true;
            }
            if (b->button == SDL_BUTTON_LEFT) {
                return te_handle_left_down(te, b->x, b->y);
            }
            enum sc_mouse_button button = sc_mouse_button_from_sdl(b->button);
            if (button != SC_MOUSE_BUTTON_UNKNOWN) {
                te_bind(te, SC_KEYBOARD_GAMEPAD_INPUT_MOUSE_BUTTON, button);
            }
            return true;
        }
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if (event->button.button == SDL_BUTTON_LEFT) {
                te->drag = SC_TOUCH_EDITOR_DRAG_NONE;
            }
            return true;
        case SDL_EVENT_MOUSE_MOTION:
            if (te->drag != SC_TOUCH_EDITOR_DRAG_NONE
                    && event->motion.which != SDL_TOUCH_MOUSEID) {
                te_drag_to(te, event->motion.x, event->motion.y);
            }
            return true;
        case SDL_EVENT_MOUSE_WHEEL:
            if (te->selection == SC_TOUCH_EDITOR_SELECTION_AIM
                    && event->wheel.y) {
                int32_t s = (int32_t) te->kt->aim_sensitivity
                          + (event->wheel.y > 0 ? 10 : -10);
                if (s < TE_MIN_SENSITIVITY) {
                    s = TE_MIN_SENSITIVITY;
                } else if (s > TE_MAX_SENSITIVITY) {
                    s = TE_MAX_SENSITIVITY;
                }
                te->kt->aim_sensitivity = (uint32_t) s;
                te->changed = true;
            }
            return true;
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_UP:
        case SDL_EVENT_FINGER_MOTION:
            return true;
        default:
            return false;
    }
}

// Drawing, in the renderer's pixels

struct te_paint {
    SDL_Renderer *renderer;
    float d; // pixels per window point
    float k; // the debug font's scale
    SDL_FRect view; // text is kept inside it
};

static void
te_color(const struct te_paint *p, uint8_t r, uint8_t g, uint8_t b,
         uint8_t a) {
    SDL_SetRenderDrawColor(p->renderer, r, g, b, a);
}

static void
te_fill_rect(const struct te_paint *p, SDL_FRect r) {
    SDL_FRect px = {r.x * p->d, r.y * p->d, r.w * p->d, r.h * p->d};
    SDL_RenderFillRect(p->renderer, &px);
}

static void
te_outline_rect(const struct te_paint *p, SDL_FRect r) {
    SDL_FRect px = {r.x * p->d, r.y * p->d, r.w * p->d, r.h * p->d};
    SDL_RenderRect(p->renderer, &px);
}

static void
te_fill_circle(const struct te_paint *p, float cx, float cy, float radius,
               SDL_FColor color) {
    SDL_Vertex v[TE_CIRCLE_SEGMENTS + 1];
    int indices[TE_CIRCLE_SEGMENTS * 3];
    v[0] = (SDL_Vertex) {{cx * p->d, cy * p->d}, color, {0, 0}};
    for (int i = 0; i < TE_CIRCLE_SEGMENTS; ++i) {
        float a = 2 * (float) M_PI * i / TE_CIRCLE_SEGMENTS;
        v[i + 1] = (SDL_Vertex) {
            {(cx + radius * cosf(a)) * p->d, (cy + radius * sinf(a)) * p->d},
            color, {0, 0}};
        indices[i * 3] = 0;
        indices[i * 3 + 1] = i + 1;
        indices[i * 3 + 2] = (i + 1) % TE_CIRCLE_SEGMENTS + 1;
    }
    SDL_RenderGeometry(p->renderer, NULL, v, TE_CIRCLE_SEGMENTS + 1, indices,
                       TE_CIRCLE_SEGMENTS * 3);
}

static void
te_ring(const struct te_paint *p, float cx, float cy, float radius,
        float width) {
    // Concentric outlines, about a pixel apart
    int lines = (int) (width * p->d + 0.5f);
    if (lines < 1) {
        lines = 1;
    }
    for (int l = 0; l < lines; ++l) {
        float r = radius * p->d - l + lines / 2.f;
        SDL_FPoint pts[TE_CIRCLE_SEGMENTS * 2 + 1];
        int n = TE_CIRCLE_SEGMENTS * 2;
        for (int i = 0; i <= n; ++i) {
            float a = 2 * (float) M_PI * i / n;
            pts[i] = (SDL_FPoint) {cx * p->d + r * cosf(a),
                                   cy * p->d + r * sinf(a)};
        }
        SDL_RenderLines(p->renderer, pts, n + 1);
    }
}

// The width of text in window points
static float
te_text_width(const struct te_paint *p, const char *text) {
    return strlen(text) * SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * p->k / p->d;
}

static float
te_text_height(const struct te_paint *p) {
    return SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * p->k / p->d;
}

// Text at (x, y), its top left corner in window points, with a shadow
static void
te_text(const struct te_paint *p, float x, float y, const char *text,
        uint8_t r, uint8_t g, uint8_t b) {
    float px = x * p->d / p->k;
    float py = y * p->d / p->k;
    // The shadow a pixel or two down and right
    float o = (p->d >= 1.5f ? 2.f : 1.f) / p->k;
    SDL_SetRenderScale(p->renderer, p->k, p->k);
    SDL_SetRenderDrawColor(p->renderer, 0, 0, 0, 0xFF);
    SDL_RenderDebugText(p->renderer, px + o, py + o, text);
    SDL_SetRenderDrawColor(p->renderer, r, g, b, 0xFF);
    SDL_RenderDebugText(p->renderer, px, py, text);
    SDL_SetRenderScale(p->renderer, 1, 1);
}

static void
te_text_centered(const struct te_paint *p, float cx, float cy,
                 const char *text, uint8_t r, uint8_t g, uint8_t b) {
    float w = te_text_width(p, text);
    float h = te_text_height(p);
    float x = cx - w / 2;
    float y = cy - h / 2;
    // Inside the display, whole, near its edges too
    if (p->view.w) {
        x = te_clamp(x, p->view.x, p->view.x + p->view.w - w);
        y = te_clamp(y, p->view.y, p->view.y + p->view.h - h);
    }
    te_text(p, x, y, text, r, g, b);
}

// The names of target's keys, separated by spaces, or "?" for none
static void
te_keys_label(const struct sc_keyboard_touch *kt, int target, char *buf,
              size_t size) {
    size_t len = 0;
    buf[0] = '\0';
    for (size_t i = 0; i < kt->key_count && len + 1 < size; ++i) {
        if (kt->keys[i].target != target) {
            continue;
        }
        char name[64];
        sc_keyboard_touch_key_name(&kt->keys[i], false, name, sizeof(name));
        int n = snprintf(buf + len, size - len, "%s%s", len ? " " : "", name);
        if (n < 0) {
            break;
        }
        len += (size_t) n;
        if (len >= size) {
            len = size - 1;
        }
    }
    if (!len) {
        snprintf(buf, size, "?");
    }
}

static const SDL_FColor te_fill = {0.15f, 0.45f, 1.0f, 0.55f};
static const SDL_FColor te_fill_selected = {1.0f, 0.75f, 0.0f, 0.70f};

static void
te_draw_ring_control(struct sc_touch_editor *te, const struct te_paint *p,
                     const struct sc_keyboard_touch_point *point,
                     bool selected) {
    float cx = te_x(te, point->x);
    float cy = te_y(te, point->y);
    float r = te_r(te, point->r);
    if (selected) {
        te_color(p, 0xFF, 0xC0, 0x00, 0xFF);
    } else {
        te_color(p, 0xFF, 0xFF, 0xFF, 0xD0);
    }
    te_ring(p, cx, cy, r, 2);
    te_fill_circle(p, cx, cy, TE_HANDLE_RADIUS,
                   selected ? te_fill_selected : te_fill);
}

static void
te_draw_joystick(struct sc_touch_editor *te, const struct te_paint *p) {
    const struct sc_keyboard_touch *kt = te->kt;
    bool selected = te->selection == SC_TOUCH_EDITOR_SELECTION_JOYSTICK;
    te_draw_ring_control(te, p, &kt->joystick, selected);
    float cx = te_x(te, kt->joystick.x);
    float cy = te_y(te, kt->joystick.y);
    float r = te_r(te, kt->joystick.r);
    float h = te_text_height(p);
    // Each direction's keys just inside the ring
    const float at[4][2] = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};
    for (int i = 0; i < 4; ++i) {
        char label[96];
        te_keys_label(kt, te_directions[i], label, sizeof(label));
        float inset = at[i][0] ? te_text_width(p, label) / 2 + 4 : h;
        float x = cx + at[i][0] * (r - inset);
        float y = cy + at[i][1] * (r - inset);
        bool next = selected && te->direction == i;
        if (next) {
            te_text_centered(p, x, y, label, 0xFF, 0xC0, 0x00);
        } else {
            te_text_centered(p, x, y, label, 0xFF, 0xFF, 0xFF);
        }
    }
    // The walk and sprint keys under the ring
    float y = cy + r + h;
    for (int i = 4; i < 6; ++i) {
        char keys[96];
        char label[128];
        te_keys_label(kt, te_directions[i], keys, sizeof(keys));
        snprintf(label, sizeof(label), "%s: %s", te_direction_names[i],
                 strcmp(keys, "?") ? keys : "none");
        bool next = selected && te->direction == i;
        te_text_centered(p, cx, y, label, 0xFF, next ? 0xC0 : 0xFF,
                         next ? 0x00 : 0xFF);
        y += h * 1.4f;
    }
}

// The character, where skill casts aim from: a cross in a ring
static void
te_draw_cast_center(struct sc_touch_editor *te, const struct te_paint *p) {
    const struct sc_keyboard_touch *kt = te->kt;
    bool selected = te->selection == SC_TOUCH_EDITOR_SELECTION_CAST_CENTER;
    float cx = te_x(te, kt->cast_center.x);
    float cy = te_y(te, kt->cast_center.y);
    if (selected) {
        te_color(p, 0xFF, 0xC0, 0x00, 0xFF);
    } else {
        te_color(p, 0xFF, 0xFF, 0xFF, 0xD0);
    }
    te_ring(p, cx, cy, TE_HANDLE_RADIUS, 1.5f);
    SDL_RenderLine(p->renderer, (cx - TE_HANDLE_RADIUS) * p->d, cy * p->d,
                   (cx + TE_HANDLE_RADIUS) * p->d, cy * p->d);
    SDL_RenderLine(p->renderer, cx * p->d, (cy - TE_HANDLE_RADIUS) * p->d,
                   cx * p->d, (cy + TE_HANDLE_RADIUS) * p->d);
    te_text_centered(p, cx, cy + TE_HANDLE_RADIUS + te_text_height(p),
                     "character", 0xFF, 0xFF, 0xFF);
}

static void
te_draw_aim(struct sc_touch_editor *te, const struct te_paint *p) {
    const struct sc_keyboard_touch *kt = te->kt;
    bool selected = te->selection == SC_TOUCH_EDITOR_SELECTION_AIM;
    te_draw_ring_control(te, p, &kt->aim, selected);
    float cx = te_x(te, kt->aim.x);
    float cy = te_y(te, kt->aim.y);
    char label[32];
    snprintf(label, sizeof(label), "Aim %u%%",
             (unsigned) kt->aim_sensitivity);
    te_text_centered(p, cx, cy + TE_HANDLE_RADIUS + te_text_height(p), label,
                     0xFF, 0xFF, 0xFF);
}

static void
te_draw_taps(struct sc_touch_editor *te, const struct te_paint *p) {
    const struct sc_keyboard_touch *kt = te->kt;
    for (size_t i = 0; i < kt->tap_count; ++i) {
        bool selected = te->selection == SC_TOUCH_EDITOR_SELECTION_TAP
                     && te->tap == (int) i;
        float cx = te_x(te, kt->taps[i].x);
        float cy = te_y(te, kt->taps[i].y);
        te_fill_circle(p, cx, cy, TE_TAP_RADIUS,
                       selected ? te_fill_selected : te_fill);
        if (selected) {
            te_color(p, 0xFF, 0xC0, 0x00, 0xFF);
        } else {
            te_color(p, 0xFF, 0xFF, 0xFF, 0xD0);
        }
        te_ring(p, cx, cy, TE_TAP_RADIUS, 1.5f);
        if (kt->kinds[i] == SC_KEYBOARD_TOUCH_CAST) {
            // Its reach
            te_ring(p, cx, cy, te_r(te, kt->taps[i].r), 1);
        }
        char label[96];
        te_keys_label(kt, (int) i, label, sizeof(label));
        te_text_centered(p, cx, cy, label, 0xFF, 0xFF, 0xFF);
    }
    if (te_has_casts(kt)) {
        te_draw_cast_center(te, p);
    }
}

// The line under the toolbar's buttons, for what is selected
static void
te_hint(const struct sc_touch_editor *te, char *buf, size_t size) {
    const struct sc_keyboard_touch *kt = te->kt;
    char keys[96];
    switch (te->selection) {
        case SC_TOUCH_EDITOR_SELECTION_TAP:
            if (!te_tap_has_keys(kt, te->tap)) {
                snprintf(buf, size, "Press this point's key, or click a "
                         "mouse button (Left click above). Drag to move.");
            } else if (kt->kinds[te->tap] == SC_KEYBOARD_TOUCH_CAST) {
                te_keys_label(kt, te->tap, keys, sizeof(keys));
                snprintf(buf, size, "Skill cast, keys %s: held, it slides "
                         "toward the pointer. Drag its ring to set its "
                         "reach.", keys);
            } else {
                te_keys_label(kt, te->tap, keys, sizeof(keys));
                snprintf(buf, size, "Keys: %s. A key adds or removes one. "
                         "Drag to move. Delete removes the point.", keys);
            }
            return;
        case SC_TOUCH_EDITOR_SELECTION_CAST_CENTER:
            snprintf(buf, size, "The character: skill casts aim from here "
                     "toward the pointer. Drag it onto the character.");
            return;
        case SC_TOUCH_EDITOR_SELECTION_JOYSTICK:
            te_keys_label(kt, te_directions[te->direction], keys,
                          sizeof(keys));
            snprintf(buf, size, "Press the key for %s (now %s). Drag the "
                     "middle to move, the ring to resize.",
                     te_direction_names[te->direction],
                     strcmp(keys, "?") ? keys : "none");
            return;
        case SC_TOUCH_EDITOR_SELECTION_AIM:
            snprintf(buf, size, "The mouse turns the view from here. Wheel: "
                     "sensitivity %u%%. Drag the ring to resize.",
                     (unsigned) kt->aim_sensitivity);
            return;
        default:
            snprintf(buf, size, "Click where a key should touch, then press "
                     "the key. Drag to move. MOD+t or Done saves.");
            return;
    }
}

// The toolbar's buttons at the top middle, and the line for what is
// selected at the bottom middle, each on a dark band only as wide as it is;
// the controls are drawn over them, so that none is hidden
static void
te_draw_toolbar(struct sc_touch_editor *te, const struct te_paint *p) {
    float h = te_text_height(p);
    float pad = TE_PADDING;

    float width = pad;
    for (int i = 0; i < SC_TOUCH_EDITOR_BUTTON_COUNT; ++i) {
        width += te_text_width(p, te_button_labels[i]) + 3 * pad;
    }
    SDL_FRect bar = {te->view.x + (te->view.w - width) / 2, te->view.y,
                     width, h + 4 * pad};
    te_color(p, 0x10, 0x10, 0x10, 0xD8);
    te_fill_rect(p, bar);
    te->bar = bar;

    float x = bar.x + pad;
    float y = bar.y + pad;
    bool has_selection = te->selection != SC_TOUCH_EDITOR_SELECTION_NONE;
    for (int i = 0; i < SC_TOUCH_EDITOR_BUTTON_COUNT; ++i) {
        const char *label = te_button_labels[i];
        SDL_FRect r = {x, y, te_text_width(p, label) + 2 * pad, h + 2 * pad};
        bool enabled = true;
        if (i == TE_BUTTON_LEFT_CLICK || i == TE_BUTTON_CAST) {
            enabled = te->selection == SC_TOUCH_EDITOR_SELECTION_TAP;
        } else if (i == TE_BUTTON_DELETE) {
            enabled = has_selection;
        }
        te_color(p, 0x40, 0x40, 0x40, 0xFF);
        te_fill_rect(p, r);
        te_color(p, 0xA0, 0xA0, 0xA0, 0xFF);
        te_outline_rect(p, r);
        uint8_t c = enabled ? 0xFF : 0x80;
        te_text(p, x + pad, y + pad, label, c, c, c);
        te->buttons[i] = r;
        x += r.w + pad;
    }
    te->has_buttons = true;

    char hint[256];
    te_hint(te, hint, sizeof(hint));
    // Broken into lines at spaces where it is wider than the display
    float max_w = te->view.w - 4 * pad;
    size_t max_chars = (size_t) (max_w / te_text_width(p, "M"));
    if (max_chars < 8) {
        max_chars = 8;
    }
    char lines[TE_HINT_MAX_LINES][256];
    int count = 0;
    const char *rest = hint;
    while (*rest && count < TE_HINT_MAX_LINES) {
        size_t len = strlen(rest);
        if (len > max_chars && count < TE_HINT_MAX_LINES - 1) {
            len = max_chars;
            while (len && rest[len] != ' ') {
                --len;
            }
            if (!len) {
                len = max_chars;
            }
        }
        if (len >= sizeof(lines[0])) {
            len = sizeof(lines[0]) - 1;
        }
        memcpy(lines[count], rest, len);
        lines[count][len] = '\0';
        ++count;
        rest += len;
        while (*rest == ' ') {
            ++rest;
        }
    }
    float hw = 0;
    for (int i = 0; i < count; ++i) {
        float w = te_text_width(p, lines[i]);
        hw = w > hw ? w : hw;
    }
    hw += 2 * pad;
    float lh = h + pad;
    SDL_FRect band = {te->view.x + (te->view.w - hw) / 2,
                      te->view.y + te->view.h - count * lh - 2 * pad, hw,
                      count * lh + pad};
    te_color(p, 0x10, 0x10, 0x10, 0xD8);
    te_fill_rect(p, band);
    for (int i = 0; i < count; ++i) {
        float w = te_text_width(p, lines[i]);
        te_text(p, band.x + (hw - w) / 2, band.y + pad + i * lh, lines[i],
                0xFF, 0xE0, 0x80);
    }
}

// The toolbar's width, for the size of the text
static float
te_toolbar_width(const struct te_paint *p) {
    float width = TE_PADDING;
    for (int i = 0; i < SC_TOUCH_EDITOR_BUTTON_COUNT; ++i) {
        width += te_text_width(p, te_button_labels[i]) + 3 * TE_PADDING;
    }
    return width;
}

void
sc_touch_editor_render(struct sc_touch_editor *te, SDL_Renderer *renderer) {
    if (!te->view.w || !te->view.h) {
        return;
    }
    struct te_paint p = {
        .renderer = renderer,
        .d = te->density,
        // The debug font's 8-pixel glyphs, about 14 to 16 points high
        .k = te->density >= 1.5f ? roundf(te->density * 1.75f) : 2,
        .view = te->view,
    };
    // Smaller text where the toolbar would not fit across the display
    while (p.k > 1 && te_toolbar_width(&p) > te->view.w) {
        --p.k;
    }

    SDL_BlendMode blend;
    SDL_GetRenderDrawBlendMode(renderer, &blend);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);

    // The game, dimmed
    te_color(&p, 0, 0, 0, 0x60);
    te_fill_rect(&p, te->view);

    te_draw_toolbar(te, &p);
    if (te->kt->has_joystick) {
        te_draw_joystick(te, &p);
    }
    if (te->kt->has_aim) {
        te_draw_aim(te, &p);
    }
    te_draw_taps(te, &p);

    SDL_SetRenderDrawBlendMode(renderer, blend);
}

void
sc_touch_editor_render_hints(struct sc_touch_editor *te,
                             SDL_Renderer *renderer) {
    if (!te->view.w || !te->view.h) {
        return;
    }
    const struct sc_keyboard_touch *kt = te->kt;
    struct te_paint p = {
        .renderer = renderer,
        .d = te->density,
        .k = te->density >= 1.5f ? roundf(te->density * 1.5f) : 2,
        .view = te->view,
    };
    struct sc_size size = te->device;
    if (!size.width || !size.height) {
        return;
    }
    // From the device display's pixels to window points
    float sx = te->view.w / size.width;
    float sy = te->view.h / size.height;

    SDL_BlendMode blend;
    SDL_GetRenderDrawBlendMode(renderer, &blend);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
    static const SDL_FColor faint = {0.0f, 0.0f, 0.0f, 0.35f};

    for (size_t i = 0; i < kt->tap_count; ++i) {
        float x = te->view.x
                + sc_keyboard_touch_px_x(kt, &kt->taps[i], size) * sx;
        float y = te->view.y
                + sc_keyboard_touch_px_y(kt, &kt->taps[i], size) * sy;
        char label[96];
        te_keys_label(kt, (int) i, label, sizeof(label));
        float w = te_text_width(&p, label);
        float h = te_text_height(&p);
        te_fill_circle(&p, x, y, (w > h ? w : h) / 2 + 4, faint);
        te_text_centered(&p, x, y, label, 0xFF, 0xFF, 0xFF);
    }
    if (kt->has_joystick) {
        float x = te->view.x
                + sc_keyboard_touch_px_x(kt, &kt->joystick, size) * sx;
        float y = te->view.y
                + sc_keyboard_touch_px_y(kt, &kt->joystick, size) * sy;
        char label[128] = "";
        size_t len = 0;
        for (int d = 0; d < 4; ++d) {
            char keys[32];
            te_keys_label(kt, te_directions[d], keys, sizeof(keys));
            len += snprintf(label + len, sizeof(label) - len, "%s%s",
                            d ? " " : "", keys);
            if (len >= sizeof(label)) {
                break;
            }
        }
        te_text_centered(&p, x, y, label, 0xFF, 0xFF, 0xFF);
    }
    if (kt->has_aim) {
        float x = te->view.x + sc_keyboard_touch_px_x(kt, &kt->aim, size) * sx;
        float y = te->view.y + sc_keyboard_touch_px_y(kt, &kt->aim, size) * sy;
        te_color(&p, 0xFF, 0xFF, 0xFF, 0x80);
        te_ring(&p, x, y, TE_HANDLE_RADIUS, 1);
    }

    SDL_SetRenderDrawBlendMode(renderer, blend);
}
