#ifndef SC_CF_SOURCE_H
#define SC_CF_SOURCE_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <libavutil/buffer.h>
#include <libavutil/frame.h>

#include "coords.h"
#include "ika/latency.h"
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
 * it, when the last reference to the frame is dropped. Likewise, the server
 * holds the guest's buffer of a DMA-BUF frame until the frame is released.
 */
struct sc_cf_source {
    struct sc_frame_source frame_source; // frame source trait

    char *socket_path;
    uint32_t display_number; // the Cuttlefish (crosvm) display number
    // If set, the window is opened at this size as soon as the socket is
    // connected, instead of on the first frame: the display of a new app window
    // may present nothing until the app is started, which waits for the window
    // size
    struct sc_size open_size;

    sc_thread thread;
    sc_mutex mutex;
    bool stopped;
    int fd; // the connected socket, -1 if none

    // Shared memory slots, mapped from the server (IKAS message), a
    // struct sc_cf_shm referenced by the frames pointing into it
    AVBufferRef *shm;
    // The connection (a struct sc_cf_conn), referenced by the DMA-BUF frames
    // to release when they are freed
    AVBufferRef *conn;

    AVBufferPool *pool;
    size_t pool_size;
    AVFrame *frame;
    bool sinks_open;

    // Ask the server for the frames' timestamps (IKAT, with IKA_LATENCY=1),
    // and the ones received for the next frame, attached to it as its
    // opaque_ref (a struct sc_latency_stamps)
    bool want_stamps;
    bool stamps_pending;
    struct sc_latency_stamps stamps;

    // The window is hidden: the server keeps the frames instead of sending them
    // (protected by mutex)
    bool window_hidden;
};

bool
sc_cf_source_init(struct sc_cf_source *source, const char *socket_path,
                  uint32_t display_number, struct sc_size open_size,
                  bool want_stamps);

bool
sc_cf_source_start(struct sc_cf_source *source);

void
sc_cf_source_stop(struct sc_cf_source *source);

/**
 * Tell the server whether the window is hidden (minimized or occluded): it
 * then stops sending frames, and sends the latest one when the window is shown.
 */
void
sc_cf_source_set_window_hidden(struct sc_cf_source *source, bool hidden);

void
sc_cf_source_join(struct sc_cf_source *source);

void
sc_cf_source_destroy(struct sc_cf_source *source);

#endif
