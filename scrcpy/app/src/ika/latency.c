#include "latency.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "util/log.h"

void
sc_latency_init(struct sc_latency *latency) {
    memset(latency, 0, sizeof(*latency));
    const char *env = getenv("IKA_LATENCY");
    latency->enabled = env && *env && strcmp(env, "0") != 0;
    if (latency->enabled) {
        LOGI("Frame latency statistics enabled (IKA_LATENCY)");
    }
}

bool
sc_latency_enabled(const struct sc_latency *latency) {
    return latency->enabled;
}

uint64_t
sc_latency_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ull + (uint64_t) ts.tv_nsec;
}

static uint32_t
sc_latency_us(uint64_t from_ns, uint64_t to_ns) {
    if (to_ns <= from_ns) {
        return 0;
    }
    uint64_t us = (to_ns - from_ns) / 1000;
    return us > UINT32_MAX ? UINT32_MAX : (uint32_t) us;
}

static int
sc_latency_compare(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *) a;
    uint32_t y = *(const uint32_t *) b;
    return (x > y) - (x < y);
}

// The p-th percentile (0-100) of the stage's samples, in microseconds
static uint32_t
sc_latency_percentile(const struct sc_latency *latency,
                      enum sc_latency_stage stage, unsigned p,
                      uint32_t *sorted) {
    unsigned n = latency->count;
    memcpy(sorted, latency->samples[stage], n * sizeof(*sorted));
    qsort(sorted, n, sizeof(*sorted), sc_latency_compare);
    unsigned i = (unsigned) (((uint64_t) p * (n - 1) + 50) / 100);
    return sorted[i];
}

static void
sc_latency_log(struct sc_latency *latency) {
    static const char *const names[SC_LATENCY_STAGE_COUNT] = {
        [SC_LATENCY_SERVER] = "server",
        [SC_LATENCY_SOCKET] = "socket",
        [SC_LATENCY_CLIENT] = "client",
        [SC_LATENCY_TOTAL] = "total",
    };
    uint32_t sorted[SC_LATENCY_SAMPLES];
    char line[256];
    size_t len = 0;
    for (unsigned s = 0; s < SC_LATENCY_STAGE_COUNT; ++s) {
        uint32_t p50 = sc_latency_percentile(latency, s, 50, sorted);
        uint32_t p90 = sc_latency_percentile(latency, s, 90, sorted);
        uint32_t p99 = sc_latency_percentile(latency, s, 99, sorted);
        int r = snprintf(line + len, sizeof(line) - len,
                         "%s%s %.1f/%.1f/%.1f", len ? ", " : "", names[s],
                         p50 / 1000.0, p90 / 1000.0, p99 / 1000.0);
        if (r < 0 || (size_t) r >= sizeof(line) - len) {
            break;
        }
        len += r;
    }
    LOGI("Frame latency ms p50/p90/p99 over %u frames: %s (%u skipped)",
         latency->count, line, latency->skipped);
}

void
sc_latency_add_presented(struct sc_latency *latency,
                         const struct sc_latency_stamps *stamps) {
    if (!latency->enabled) {
        return;
    }
    uint64_t present_ns = sc_latency_now_ns();
    unsigned i = latency->next;
    latency->samples[SC_LATENCY_SERVER][i] =
        sc_latency_us(stamps->arrival_ns, stamps->send_ns);
    latency->samples[SC_LATENCY_SOCKET][i] =
        sc_latency_us(stamps->send_ns, stamps->recv_ns);
    latency->samples[SC_LATENCY_CLIENT][i] =
        sc_latency_us(stamps->recv_ns, present_ns);
    latency->samples[SC_LATENCY_TOTAL][i] =
        sc_latency_us(stamps->arrival_ns, present_ns);
    latency->next = (i + 1) % SC_LATENCY_SAMPLES;
    if (latency->count < SC_LATENCY_SAMPLES) {
        ++latency->count;
    }
    if (++latency->since_log >= SC_LATENCY_LOG_PERIOD) {
        sc_latency_log(latency);
        latency->since_log = 0;
        latency->skipped = 0;
    }
}

void
sc_latency_add_skipped(struct sc_latency *latency) {
    if (latency->enabled) {
        ++latency->skipped;
    }
}
