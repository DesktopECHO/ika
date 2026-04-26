#ifndef SC_CUTTLEFISH_FRAME_SOURCE_H
#define SC_CUTTLEFISH_FRAME_SOURCE_H

#include "common.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "screen.h"
#include "util/thread.h"

struct sc_cuttlefish_frame_source {
    sc_thread thread;
    sc_mutex mutex;
    bool stopped;
    int socket_fd;
    char *socket_path;
    uint32_t display_id;
    struct sc_screen *screen;
    uint8_t *shm_data;
    size_t shm_size;
    uint32_t shm_slot_count;
    uint32_t shm_slot_size;
};

bool
sc_cuttlefish_frame_source_init(struct sc_cuttlefish_frame_source *source,
                                const char *socket_path,
                                uint32_t display_id,
                                struct sc_screen *screen);

bool
sc_cuttlefish_frame_source_start(struct sc_cuttlefish_frame_source *source);

void
sc_cuttlefish_frame_source_stop(struct sc_cuttlefish_frame_source *source);

void
sc_cuttlefish_frame_source_join(struct sc_cuttlefish_frame_source *source);

void
sc_cuttlefish_frame_source_destroy(struct sc_cuttlefish_frame_source *source);

#endif
