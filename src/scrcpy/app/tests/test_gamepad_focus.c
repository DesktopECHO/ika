#include "common.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "ika/gamepad_focus.h"

// The device's side: which gamepads it has, and the events they got
struct device {
    struct sc_gamepad_processor gp;
    uint32_t ids[8];
    const char *names[8];
    size_t count;
    unsigned inputs;
    uint32_t last_input_id;
};

static struct device d;
static struct sc_gamepad_focus gf;

static bool
has(uint32_t id) {
    for (size_t i = 0; i < d.count; ++i) {
        if (d.ids[i] == id) {
            return true;
        }
    }
    return false;
}

static void
device_added(struct sc_gamepad_processor *gp,
             const struct sc_gamepad_device_event *event) {
    (void) gp;
    assert(!has(event->gamepad_id));
    d.names[d.count] = event->name;
    d.ids[d.count++] = event->gamepad_id;
}

static void
device_removed(struct sc_gamepad_processor *gp,
               const struct sc_gamepad_device_event *event) {
    (void) gp;
    assert(has(event->gamepad_id));
    size_t i = 0;
    while (d.ids[i] != event->gamepad_id) {
        ++i;
    }
    d.ids[i] = d.ids[--d.count];
    d.names[i] = d.names[d.count];
}

static void
device_input(uint32_t id) {
    assert(has(id));
    d.inputs++;
    d.last_input_id = id;
}

static void
device_axis(struct sc_gamepad_processor *gp,
            const struct sc_gamepad_axis_event *event) {
    (void) gp;
    device_input(event->gamepad_id);
}

static void
device_button(struct sc_gamepad_processor *gp,
              const struct sc_gamepad_button_event *event) {
    (void) gp;
    device_input(event->gamepad_id);
}

static void
device_stick(struct sc_gamepad_processor *gp,
             const struct sc_gamepad_stick_event *event) {
    (void) gp;
    device_input(event->gamepad_id);
}

static const struct sc_gamepad_processor_ops device_ops = {
    .process_gamepad_added = device_added,
    .process_gamepad_removed = device_removed,
    .process_gamepad_axis = device_axis,
    .process_gamepad_button = device_button,
    .process_gamepad_stick = device_stick,
};

static const struct sc_gamepad_processor_ops device_ops_without_stick = {
    .process_gamepad_added = device_added,
    .process_gamepad_removed = device_removed,
    .process_gamepad_axis = device_axis,
    .process_gamepad_button = device_button,
    .process_gamepad_stick = NULL,
};

#define KEYBOARD_ID UINT32_C(0xFFFFFFFF)

static struct sc_gamepad_processor *
setup(bool follow_focus) {
    memset(&d, 0, sizeof(d));
    d.gp.ops = &device_ops;
    sc_gamepad_focus_init(&gf, &d.gp, follow_focus);
    return &gf.gamepad_processor;
}

static void
connect(uint32_t id, const char *name) {
    struct sc_gamepad_device_event evt = {.gamepad_id = id, .name = name};
    gf.gamepad_processor.ops->process_gamepad_added(&gf.gamepad_processor,
                                                    &evt);
}

static void
disconnect(uint32_t id) {
    struct sc_gamepad_device_event evt = {.gamepad_id = id};
    gf.gamepad_processor.ops->process_gamepad_removed(&gf.gamepad_processor,
                                                      &evt);
}

static void
press(uint32_t id) {
    struct sc_gamepad_button_event evt = {
        .gamepad_id = id,
        .action = SC_ACTION_DOWN,
        .button = SC_GAMEPAD_BUTTON_SOUTH,
    };
    gf.gamepad_processor.ops->process_gamepad_button(&gf.gamepad_processor,
                                                     &evt);
}

// The keyboard gamepad and a real one are separate gamepads on the device,
// only while the window has the focus
static void test_separate_gamepads_while_focused(void) {
    setup(true);

    connect(KEYBOARD_ID, "Keyboard gamepad");
    connect(4, NULL);
    assert(d.count == 0); // the window has no focus yet
    press(KEYBOARD_ID);
    assert(d.inputs == 0);

    sc_gamepad_focus_set_focused(&gf, true);
    assert(d.count == 2 && has(KEYBOARD_ID) && has(4));
    assert(!strcmp(d.names[0], "Keyboard gamepad"));
    press(KEYBOARD_ID);
    assert(d.inputs == 1 && d.last_input_id == KEYBOARD_ID);
    press(4);
    assert(d.inputs == 2 && d.last_input_id == 4);

    sc_gamepad_focus_set_focused(&gf, false);
    assert(d.count == 0);
    press(4);
    assert(d.inputs == 2);

    sc_gamepad_focus_set_focused(&gf, true);
    assert(d.count == 2);
}

// Gamepads connected or disconnected while focused, and while not
static void test_hotplug(void) {
    setup(true);
    sc_gamepad_focus_set_focused(&gf, true);

    connect(4, NULL);
    assert(d.count == 1 && has(4));
    connect(4, NULL); // twice: once
    assert(d.count == 1);
    disconnect(4);
    assert(d.count == 0);
    press(4); // no longer connected
    assert(d.inputs == 0);

    sc_gamepad_focus_set_focused(&gf, false);
    connect(5, NULL);
    disconnect(5);
    connect(6, NULL);
    assert(d.count == 0);
    sc_gamepad_focus_set_focused(&gf, true);
    assert(d.count == 1 && has(6));
    disconnect(7); // unknown
    assert(d.count == 1);
}

// Without a window, the gamepads are the device's while connected
static void test_without_window(void) {
    setup(false);
    connect(KEYBOARD_ID, "Keyboard gamepad");
    assert(d.count == 1);
    press(KEYBOARD_ID);
    assert(d.inputs == 1);
}

// Sticks in one event only if the device takes them so
static void test_stick_ops_follow_device(void) {
    struct sc_gamepad_processor *gp = setup(true);
    assert(gp->ops->process_gamepad_stick);

    memset(&d, 0, sizeof(d));
    d.gp.ops = &device_ops_without_stick;
    sc_gamepad_focus_init(&gf, &d.gp, true);
    assert(!gf.gamepad_processor.ops->process_gamepad_stick);
}

int main(int argc, char *argv[]) {
    (void) argc;
    (void) argv;

    test_separate_gamepads_while_focused();
    test_hotplug();
    test_without_window();
    test_stick_ops_follow_device();
    return 0;
}
