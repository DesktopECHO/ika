#ifndef SC_CF_SOURCE_H
#define SC_CF_SOURCE_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <libavutil/buffer.h>
#include <libavutil/frame.h>

#include "trait/frame_source.h"
#include "util/thread.h"

/**
 * Frame source reading the frames of a Cuttlefish display from the Ika frame
 * socket (run_cvd's ika_stream), instead of decoding a video stream.
 *
 * The frames are uncompressed: either in a shared memory slot (or inline) as
 * packed RGB, or as a DMA-BUF (AV_PIX_FMT_DRM_PRIME). They always have the
 * physical size of the display.
 *
 * If the server supports it, the frames point into the shared memory slots
 * without a copy: the server does not rewrite a slot until the client releases
 * it, when the last reference to the frame is dropped.
 */
struct sc_cf_source {
    struct sc_frame_source frame_source; // frame source trait

    char *socket_path;
    uint32_t display_id;

    sc_thread thread;
    sc_mutex mutex;
    bool stopped;
    int fd; // the connected socket, -1 if none

    // Shared memory slots, mapped from the server (IKAS message), a
    // struct sc_cf_shm referenced by the frames pointing into it
    AVBufferRef *shm;

    AVBufferPool *pool;
    size_t pool_size;
    AVFrame *frame;
    bool sinks_open;
};

bool
sc_cf_source_init(struct sc_cf_source *source, const char *socket_path,
                  uint32_t display_id);

bool
sc_cf_source_start(struct sc_cf_source *source);

void
sc_cf_source_stop(struct sc_cf_source *source);

void
sc_cf_source_join(struct sc_cf_source *source);

void
sc_cf_source_destroy(struct sc_cf_source *source);

#endif
