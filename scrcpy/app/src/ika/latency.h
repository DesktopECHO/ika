#ifndef SC_IKA_LATENCY_H
#define SC_IKA_LATENCY_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>

/**
 * Latency statistics of the console's frames (IKA_LATENCY=1)
 *
 * Each frame of the Cuttlefish frame socket carries, when the client asked
 * the server for them (IKAT), the host's CLOCK_MONOTONIC times of its arrival
 * from crosvm (the Wayland commit) and of its notice's send; the client adds
 * its receive and present times. The stages are logged as percentiles every
 * SC_LATENCY_LOG_PERIOD frames.
 */

// The timestamps of a frame, in the AVFrame's opaque_ref (CLOCK_MONOTONIC ns)
struct sc_latency_stamps {
    uint64_t arrival_ns; // the frame came from crosvm (ika_stream)
    uint64_t send_ns; // ika_stream sent the notice
    uint64_t recv_ns; // the client received it
};

#define SC_LATENCY_SAMPLES 600
#define SC_LATENCY_LOG_PERIOD 300

enum sc_latency_stage {
    SC_LATENCY_SERVER, // arrival -> send
    SC_LATENCY_SOCKET, // send -> receive
    SC_LATENCY_CLIENT, // receive -> present
    SC_LATENCY_TOTAL, // arrival -> present
    SC_LATENCY_STAGE_COUNT,
};

struct sc_latency {
    bool enabled;
    // The last samples of each stage, in microseconds, a ring
    uint32_t samples[SC_LATENCY_STAGE_COUNT][SC_LATENCY_SAMPLES];
    unsigned count; // samples stored (up to SC_LATENCY_SAMPLES)
    unsigned next; // ring index
    unsigned since_log; // frames since the last log
    unsigned skipped; // frames dropped unshown since the last log
};

// Enabled by IKA_LATENCY=1 in the environment
void
sc_latency_init(struct sc_latency *latency);

bool
sc_latency_enabled(const struct sc_latency *latency);

uint64_t
sc_latency_now_ns(void);

// A frame was shown (presented) now, with these stamps
void
sc_latency_add_presented(struct sc_latency *latency,
                         const struct sc_latency_stamps *stamps);

// A frame was replaced by a newer one before it was shown
void
sc_latency_add_skipped(struct sc_latency *latency);

#endif
