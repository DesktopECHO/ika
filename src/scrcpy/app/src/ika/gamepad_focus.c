#include "gamepad_focus.h"

#include <assert.h>
#include <inttypes.h>

#include "util/log.h"

/** Downcast gamepad processor to sc_gamepad_focus */
#define DOWNCAST(GP) \
    container_of(GP, struct sc_gamepad_focus, gamepad_processor)

static void
sc_gamepad_focus_add(struct sc_gamepad_focus *gf, size_t i) {
    struct sc_gamepad_device_event evt = {
        .gamepad_id = gf->gamepads[i].id,
        .name = gf->gamepads[i].name,
    };
    gf->out->ops->process_gamepad_added(gf->out, &evt);
}

static void
sc_gamepad_focus_remove(struct sc_gamepad_focus *gf, size_t i) {
    struct sc_gamepad_device_event evt = {
        .gamepad_id = gf->gamepads[i].id,
    };
    gf->out->ops->process_gamepad_removed(gf->out, &evt);
}

static bool
sc_gamepad_focus_find(const struct sc_gamepad_focus *gf, uint32_t id,
                      size_t *index) {
    for (size_t i = 0; i < gf->count; ++i) {
        if (gf->gamepads[i].id == id) {
            if (index) {
                *index = i;
            }
            return true;
        }
    }
    return false;
}

static void
sc_gamepad_processor_process_gamepad_added(struct sc_gamepad_processor *gp,
                                const struct sc_gamepad_device_event *event) {
    struct sc_gamepad_focus *gf = DOWNCAST(gp);

    if (sc_gamepad_focus_find(gf, event->gamepad_id, NULL)) {
        return;
    }
    if (gf->count == SC_GAMEPAD_FOCUS_MAX_GAMEPADS) {
        LOGW("Gamepad [%" PRIu32 "] ignored: too many gamepads",
             event->gamepad_id);
        return;
    }
    size_t i = gf->count++;
    gf->gamepads[i].id = event->gamepad_id;
    gf->gamepads[i].name = event->name;
    if (gf->focused) {
        sc_gamepad_focus_add(gf, i);
    }
}

static void
sc_gamepad_processor_process_gamepad_removed(struct sc_gamepad_processor *gp,
                                const struct sc_gamepad_device_event *event) {
    struct sc_gamepad_focus *gf = DOWNCAST(gp);

    size_t i;
    if (!sc_gamepad_focus_find(gf, event->gamepad_id, &i)) {
        return;
    }
    if (gf->focused) {
        sc_gamepad_focus_remove(gf, i);
    }
    // Keep the others in the order they were connected
    for (size_t j = i + 1; j < gf->count; ++j) {
        gf->gamepads[j - 1] = gf->gamepads[j];
    }
    --gf->count;
}

static void
sc_gamepad_processor_process_gamepad_axis(struct sc_gamepad_processor *gp,
                                const struct sc_gamepad_axis_event *event) {
    struct sc_gamepad_focus *gf = DOWNCAST(gp);

    if (gf->focused && sc_gamepad_focus_find(gf, event->gamepad_id, NULL)) {
        gf->out->ops->process_gamepad_axis(gf->out, event);
    }
}

static void
sc_gamepad_processor_process_gamepad_button(struct sc_gamepad_processor *gp,
                                const struct sc_gamepad_button_event *event) {
    struct sc_gamepad_focus *gf = DOWNCAST(gp);

    if (gf->focused && sc_gamepad_focus_find(gf, event->gamepad_id, NULL)) {
        gf->out->ops->process_gamepad_button(gf->out, event);
    }
}

static void
sc_gamepad_processor_process_gamepad_stick(struct sc_gamepad_processor *gp,
                                const struct sc_gamepad_stick_event *event) {
    struct sc_gamepad_focus *gf = DOWNCAST(gp);

    if (gf->focused && sc_gamepad_focus_find(gf, event->gamepad_id, NULL)) {
        gf->out->ops->process_gamepad_stick(gf->out, event);
    }
}

void
sc_gamepad_focus_init(struct sc_gamepad_focus *gf,
                      struct sc_gamepad_processor *out, bool follow_focus) {
    assert(out && out->ops);
    gf->out = out;
    gf->count = 0;
    gf->focused = !follow_focus;

    static const struct sc_gamepad_processor_ops ops = {
        .process_gamepad_added = sc_gamepad_processor_process_gamepad_added,
        .process_gamepad_removed = sc_gamepad_processor_process_gamepad_removed,
        .process_gamepad_axis = sc_gamepad_processor_process_gamepad_axis,
        .process_gamepad_button = sc_gamepad_processor_process_gamepad_button,
        .process_gamepad_stick = sc_gamepad_processor_process_gamepad_stick,
    };
    static const struct sc_gamepad_processor_ops ops_without_stick = {
        .process_gamepad_added = sc_gamepad_processor_process_gamepad_added,
        .process_gamepad_removed = sc_gamepad_processor_process_gamepad_removed,
        .process_gamepad_axis = sc_gamepad_processor_process_gamepad_axis,
        .process_gamepad_button = sc_gamepad_processor_process_gamepad_button,
        .process_gamepad_stick = NULL,
    };
    // A gamepad sends a stick in one event only if the device's processor
    // takes it so
    gf->gamepad_processor.ops = out->ops->process_gamepad_stick
                              ? &ops : &ops_without_stick;
}

void
sc_gamepad_focus_set_focused(struct sc_gamepad_focus *gf, bool focused) {
    if (gf->focused == focused) {
        return;
    }
    gf->focused = focused;
    for (size_t i = 0; i < gf->count; ++i) {
        if (focused) {
            sc_gamepad_focus_add(gf, i);
        } else {
            sc_gamepad_focus_remove(gf, i);
        }
    }
}
