#ifndef SC_DEVICEMSG_H
#define SC_DEVICEMSG_H

#include "common.h"

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define DEVICE_MSG_MAX_SIZE (1 << 18) // 256k
// type: 1 byte; length: 4 bytes
#define DEVICE_MSG_TEXT_MAX_LENGTH (DEVICE_MSG_MAX_SIZE - 5)

enum sc_device_msg_type {
    DEVICE_MSG_TYPE_CLIPBOARD,
    DEVICE_MSG_TYPE_ACK_CLIPBOARD,
    DEVICE_MSG_TYPE_UHID_OUTPUT,
    // Sent by the device when the guest display has finished a requested
    // resize and is ready to be presented to the user (no letterbox cascade
    // in flight). Lets the client drop its stretched preview immediately
    // instead of relying on host-side heuristics.
    DEVICE_MSG_TYPE_DISPLAY_READY,
};

struct sc_device_msg {
    enum sc_device_msg_type type;
    union {
        struct {
            char *text; // owned, to be freed by free()
        } clipboard;
        struct {
            uint64_t sequence;
        } ack_clipboard;
        struct {
            uint16_t id;
            uint16_t size;
            uint8_t *data; // owned, to be freed by free()
        } uhid_output;
        struct {
            uint32_t display_id;
            uint16_t width;
            uint16_t height;
        } display_ready;
    };
};

// return the number of bytes consumed (0 for no msg available, -1 on error)
ssize_t
sc_device_msg_deserialize(const uint8_t *buf, size_t len,
                          struct sc_device_msg *msg);

void
sc_device_msg_destroy(struct sc_device_msg *msg);

#endif
