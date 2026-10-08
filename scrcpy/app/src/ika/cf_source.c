#include "cf_source.h"

#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <libavutil/hwcontext_drm.h>
#include <SDL3/SDL_timer.h>

#include "util/log.h"

// Little-endian magics spelling "IKA" + a type letter
#define SC_CF_MAGIC_RAW 0x46414b49u // IKAF: pixels follow the header
#define SC_CF_MAGIC_DMA_BUF 0x44414b49u // IKAD: a DMA-BUF fd is attached
#define SC_CF_MAGIC_SHM_INIT 0x53414b49u // IKAS: a memfd of slots is attached
#define SC_CF_MAGIC_SHM_FRAME 0x4e414b49u // IKAN: a slot holds a new frame
#define SC_CF_VERSION 1

#define SC_CF_MAX_PAYLOAD (256u * 1024 * 1024)
#define SC_CF_MAX_SLOTS 16

#define SC_FOURCC(a, b, c, d) \
    ((uint32_t) (a) | ((uint32_t) (b) << 8) | ((uint32_t) (c) << 16) \
        | ((uint32_t) (d) << 24))

struct sc_cf_header {
    uint32_t magic;
    uint32_t version;
};

// IKAF
struct sc_cf_raw_header {
    uint32_t display_number;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t stride;
    uint32_t payload_size;
};

// IKAD
struct sc_cf_dma_buf_header {
    uint32_t display_number;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t offset;
    uint32_t stride;
    uint32_t modifier_hi;
    uint32_t modifier_lo;
};

// IKAS
struct sc_cf_shm_init_header {
    uint32_t slot_count;
    uint32_t slot_size;
};

// IKAN
struct sc_cf_shm_frame_header {
    uint32_t display_number;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t stride;
    uint32_t payload_size;
    uint32_t slot_index;
};

// The DRM formats are little-endian words, so XRGB8888 is stored B, G, R, X
static enum AVPixelFormat
sc_cf_get_pix_fmt(uint32_t fourcc) {
    switch (fourcc) {
        case SC_FOURCC('X', 'R', '2', '4'): return AV_PIX_FMT_BGR0;
        case SC_FOURCC('X', 'B', '2', '4'): return AV_PIX_FMT_RGB0;
        case SC_FOURCC('R', 'X', '2', '4'): return AV_PIX_FMT_0BGR;
        case SC_FOURCC('B', 'X', '2', '4'): return AV_PIX_FMT_0RGB;
        case SC_FOURCC('A', 'R', '2', '4'): return AV_PIX_FMT_BGRA;
        case SC_FOURCC('A', 'B', '2', '4'): return AV_PIX_FMT_RGBA;
        case SC_FOURCC('R', 'A', '2', '4'): return AV_PIX_FMT_ABGR;
        case SC_FOURCC('B', 'A', '2', '4'): return AV_PIX_FMT_ARGB;
        default: return AV_PIX_FMT_NONE;
    }
}

static bool
sc_cf_check_size(uint32_t width, uint32_t height, uint32_t stride) {
    return width && width <= 0xFFFF && height && height <= 0xFFFF
        && stride >= width * 4;
}

static bool
sc_cf_is_stopped(struct sc_cf_source *source) {
    sc_mutex_lock(&source->mutex);
    bool stopped = source->stopped;
    sc_mutex_unlock(&source->mutex);
    return stopped;
}

static bool
sc_cf_read_all(int fd, void *buf, size_t size) {
    uint8_t *ptr = buf;
    while (size) {
        ssize_t r = read(fd, ptr, size);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r <= 0) {
            return false;
        }
        ptr += r;
        size -= r;
    }
    return true;
}

// Read the common header, with the file descriptor attached to it, if any
static bool
sc_cf_recv_header(int fd, struct sc_cf_header *header, int *attached_fd) {
    *attached_fd = -1;

    struct iovec iov = {
        .iov_base = header,
        .iov_len = sizeof(*header),
    };
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } control;
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = control.buf,
        .msg_controllen = sizeof(control.buf),
    };

    ssize_t r;
    do {
        r = recvmsg(fd, &msg, MSG_WAITALL | MSG_CMSG_CLOEXEC);
    } while (r < 0 && errno == EINTR);

    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg;
            cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS
                && cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
            memcpy(attached_fd, CMSG_DATA(cmsg), sizeof(int));
            break;
        }
    }

    if (r != (ssize_t) sizeof(*header)) {
        if (*attached_fd != -1) {
            close(*attached_fd);
            *attached_fd = -1;
        }
        return false;
    }
    return true;
}

static void
sc_cf_unmap_shm(struct sc_cf_source *source) {
    if (source->shm) {
        munmap(source->shm, source->shm_size);
        source->shm = NULL;
    }
    source->shm_size = 0;
    source->shm_slot_count = 0;
    source->shm_slot_size = 0;
}

static bool
sc_cf_push(struct sc_cf_source *source) {
    AVFrame *frame = source->frame;

    if (!source->sinks_open) {
        struct sc_stream_session session = {
            .video = {
                .width = frame->width,
                .height = frame->height,
                .client_resized = false,
            },
        };
        if (!sc_frame_source_sinks_open(&source->frame_source, NULL,
                                        &session)) {
            return false;
        }
        source->sinks_open = true;
    }

    enum sc_sink_result result =
        sc_frame_source_sinks_push(&source->frame_source, frame);
    av_frame_unref(frame);
    return result == SC_SINK_OK;
}

// Fill source->frame with a copy of packed RGB pixels, read from fd (if src is
// NULL) or copied from src
static bool
sc_cf_make_frame(struct sc_cf_source *source, int fd, const uint8_t *src,
                 uint32_t width, uint32_t height, uint32_t fourcc,
                 uint32_t stride, uint32_t payload_size) {
    if (!source->pool || source->pool_size != payload_size) {
        av_buffer_pool_uninit(&source->pool);
        source->pool = av_buffer_pool_init(payload_size, NULL);
        if (!source->pool) {
            LOG_OOM();
            return false;
        }
        source->pool_size = payload_size;
    }

    AVBufferRef *buf = av_buffer_pool_get(source->pool);
    if (!buf) {
        LOG_OOM();
        return false;
    }

    if (src) {
        memcpy(buf->data, src, payload_size);
    } else if (!sc_cf_read_all(fd, buf->data, payload_size)) {
        av_buffer_unref(&buf);
        return false;
    }

    AVFrame *frame = source->frame;
    frame->buf[0] = buf;
    frame->data[0] = buf->data;
    frame->linesize[0] = stride;
    frame->format = sc_cf_get_pix_fmt(fourcc);
    frame->width = width;
    frame->height = height;
    return true;
}

static void
sc_cf_free_dma_buf(void *opaque, uint8_t *data) {
    (void) opaque;
    AVDRMFrameDescriptor *desc = (AVDRMFrameDescriptor *) data;
    close(desc->objects[0].fd);
    av_free(desc);
}

static bool
sc_cf_make_dma_buf_frame(struct sc_cf_source *source,
                         const struct sc_cf_dma_buf_header *h, int dma_buf_fd) {
    AVDRMFrameDescriptor *desc = av_mallocz(sizeof(*desc));
    if (!desc) {
        LOG_OOM();
        close(dma_buf_fd);
        return false;
    }

    desc->nb_objects = 1;
    desc->objects[0].fd = dma_buf_fd;
    desc->objects[0].size = 0; // unknown
    desc->objects[0].format_modifier =
        ((uint64_t) h->modifier_hi << 32) | h->modifier_lo;
    desc->nb_layers = 1;
    desc->layers[0].format = h->fourcc;
    desc->layers[0].nb_planes = 1;
    desc->layers[0].planes[0].object_index = 0;
    desc->layers[0].planes[0].offset = h->offset;
    desc->layers[0].planes[0].pitch = h->stride;

    AVBufferRef *buf = av_buffer_create((uint8_t *) desc, sizeof(*desc),
                                        sc_cf_free_dma_buf, NULL, 0);
    if (!buf) {
        LOG_OOM();
        close(dma_buf_fd);
        av_free(desc);
        return false;
    }

    AVFrame *frame = source->frame;
    frame->buf[0] = buf;
    frame->data[0] = (uint8_t *) desc;
    frame->format = AV_PIX_FMT_DRM_PRIME;
    frame->width = h->width;
    frame->height = h->height;
    return true;
}

// Return false if the connection must be closed
static bool
sc_cf_process_msg(struct sc_cf_source *source, int fd) {
    struct sc_cf_header header;
    int attached_fd;
    if (!sc_cf_recv_header(fd, &header, &attached_fd)) {
        return false;
    }

    if (header.version != SC_CF_VERSION) {
        LOGE("Unsupported Cuttlefish frame version: %" PRIu32, header.version);
        goto error;
    }

    switch (header.magic) {
        case SC_CF_MAGIC_RAW: {
            struct sc_cf_raw_header h;
            if (!sc_cf_read_all(fd, &h, sizeof(h))) {
                goto error;
            }
            if (!sc_cf_check_size(h.width, h.height, h.stride)
                    || h.payload_size > SC_CF_MAX_PAYLOAD
                    || h.payload_size < (uint64_t) h.stride * h.height) {
                LOGE("Invalid Cuttlefish raw frame");
                goto error;
            }
            if (h.display_number != source->display_id
                    || sc_cf_get_pix_fmt(h.fourcc) == AV_PIX_FMT_NONE) {
                // Skip the payload
                uint8_t skip[4096];
                for (size_t left = h.payload_size; left;) {
                    size_t n = MIN(left, sizeof(skip));
                    if (!sc_cf_read_all(fd, skip, n)) {
                        goto error;
                    }
                    left -= n;
                }
                break;
            }
            if (!sc_cf_make_frame(source, fd, NULL, h.width, h.height,
                                  h.fourcc, h.stride, h.payload_size)) {
                goto error;
            }
            if (!sc_cf_push(source)) {
                goto error;
            }
            break;
        }
        case SC_CF_MAGIC_SHM_INIT: {
            struct sc_cf_shm_init_header h;
            if (attached_fd == -1 || !sc_cf_read_all(fd, &h, sizeof(h))
                    || !h.slot_count || h.slot_count > SC_CF_MAX_SLOTS
                    || !h.slot_size || h.slot_size > SC_CF_MAX_PAYLOAD) {
                LOGE("Invalid Cuttlefish shared memory setup");
                goto error;
            }
            size_t size = (size_t) h.slot_count * h.slot_size;
            void *shm = mmap(NULL, size, PROT_READ, MAP_SHARED, attached_fd, 0);
            close(attached_fd);
            attached_fd = -1;
            if (shm == MAP_FAILED) {
                LOGE("Could not map Cuttlefish frame slots: %s",
                     strerror(errno));
                goto error;
            }
            sc_cf_unmap_shm(source);
            source->shm = shm;
            source->shm_size = size;
            source->shm_slot_count = h.slot_count;
            source->shm_slot_size = h.slot_size;
            LOGD("Cuttlefish frame slots: %" PRIu32 " x %" PRIu32 " bytes",
                 h.slot_count, h.slot_size);
            break;
        }
        case SC_CF_MAGIC_SHM_FRAME: {
            struct sc_cf_shm_frame_header h;
            if (!sc_cf_read_all(fd, &h, sizeof(h))) {
                goto error;
            }
            if (!source->shm || h.slot_index >= source->shm_slot_count
                    || !sc_cf_check_size(h.width, h.height, h.stride)
                    || h.payload_size > source->shm_slot_size
                    || h.payload_size < (uint64_t) h.stride * h.height) {
                LOGE("Invalid Cuttlefish shared memory frame");
                goto error;
            }
            if (h.display_number != source->display_id
                    || sc_cf_get_pix_fmt(h.fourcc) == AV_PIX_FMT_NONE) {
                break;
            }
            // Copy the slot, the server reuses it for a later frame
            const uint8_t *slot =
                source->shm + (size_t) h.slot_index * source->shm_slot_size;
            if (!sc_cf_make_frame(source, fd, slot, h.width, h.height,
                                  h.fourcc, h.stride, h.payload_size)) {
                goto error;
            }
            if (!sc_cf_push(source)) {
                goto error;
            }
            break;
        }
        case SC_CF_MAGIC_DMA_BUF: {
            struct sc_cf_dma_buf_header h;
            if (attached_fd == -1 || !sc_cf_read_all(fd, &h, sizeof(h))
                    || !sc_cf_check_size(h.width, h.height, h.stride)) {
                LOGE("Invalid Cuttlefish DMA-BUF frame");
                goto error;
            }
            if (h.display_number != source->display_id
                    || sc_cf_get_pix_fmt(h.fourcc) == AV_PIX_FMT_NONE) {
                break;
            }
            int dma_buf_fd = attached_fd;
            attached_fd = -1;
            if (!sc_cf_make_dma_buf_frame(source, &h, dma_buf_fd)) {
                goto error;
            }
            if (!sc_cf_push(source)) {
                goto error;
            }
            break;
        }
        default:
            LOGE("Invalid Cuttlefish frame message: %#" PRIx32, header.magic);
            goto error;
    }

    if (attached_fd != -1) {
        close(attached_fd);
    }
    return true;

error:
    if (attached_fd != -1) {
        close(attached_fd);
    }
    return false;
}

static int
sc_cf_connect(const char *path) {
    struct sockaddr_un addr = {
        .sun_family = AF_UNIX,
    };
    if (strlen(path) >= sizeof(addr.sun_path)) {
        LOGE("Cuttlefish frame socket path too long: %s", path);
        return -1;
    }
    strcpy(addr.sun_path, path);

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd == -1) {
        return -1;
    }
    if (connect(fd, (struct sockaddr *) &addr, sizeof(addr)) == -1) {
        close(fd);
        return -1;
    }
    return fd;
}

static int
run_cf_source(void *data) {
    struct sc_cf_source *source = data;
    bool error_logged = false;

    while (!sc_cf_is_stopped(source)) {
        int fd = sc_cf_connect(source->socket_path);
        if (fd == -1) {
            if (!error_logged) {
                LOGW("Could not connect to Cuttlefish frame socket %s: %s",
                     source->socket_path, strerror(errno));
                error_logged = true;
            }
            SDL_Delay(100);
            continue;
        }

        sc_mutex_lock(&source->mutex);
        bool stopped = source->stopped;
        if (!stopped) {
            source->fd = fd;
        }
        sc_mutex_unlock(&source->mutex);
        if (stopped) {
            close(fd);
            break;
        }

        error_logged = false;
        LOGD("Connected to Cuttlefish frame socket %s", source->socket_path);

        while (sc_cf_process_msg(source, fd));

        sc_mutex_lock(&source->mutex);
        source->fd = -1;
        stopped = source->stopped;
        sc_mutex_unlock(&source->mutex);
        close(fd);
        sc_cf_unmap_shm(source);
        av_frame_unref(source->frame);

        if (!stopped) {
            LOGW("Cuttlefish frame socket disconnected, reconnecting");
            SDL_Delay(250);
        }
    }

    if (source->sinks_open) {
        sc_frame_source_sinks_close(&source->frame_source);
        source->sinks_open = false;
    }

    return 0;
}

bool
sc_cf_source_init(struct sc_cf_source *source, const char *socket_path,
                  uint32_t display_id) {
    source->socket_path = strdup(socket_path);
    if (!source->socket_path) {
        LOG_OOM();
        return false;
    }

    source->frame = av_frame_alloc();
    if (!source->frame) {
        LOG_OOM();
        free(source->socket_path);
        return false;
    }

    if (!sc_mutex_init(&source->mutex)) {
        av_frame_free(&source->frame);
        free(source->socket_path);
        return false;
    }

    source->display_id = display_id;
    source->stopped = false;
    source->fd = -1;
    source->shm = NULL;
    source->shm_size = 0;
    source->shm_slot_count = 0;
    source->shm_slot_size = 0;
    source->pool = NULL;
    source->pool_size = 0;
    source->sinks_open = false;

    sc_frame_source_init(&source->frame_source);
    return true;
}

bool
sc_cf_source_start(struct sc_cf_source *source) {
    bool ok = sc_thread_create(&source->thread, run_cf_source, "scrcpy-cf",
                               source);
    if (!ok) {
        LOGE("Could not start Cuttlefish frame source thread");
    }
    return ok;
}

void
sc_cf_source_stop(struct sc_cf_source *source) {
    sc_mutex_lock(&source->mutex);
    source->stopped = true;
    if (source->fd != -1) {
        // Unblock the reader
        shutdown(source->fd, SHUT_RDWR);
    }
    sc_mutex_unlock(&source->mutex);
}

void
sc_cf_source_join(struct sc_cf_source *source) {
    sc_thread_join(&source->thread, NULL);
}

void
sc_cf_source_destroy(struct sc_cf_source *source) {
    sc_cf_unmap_shm(source);
    av_buffer_pool_uninit(&source->pool);
    av_frame_free(&source->frame);
    sc_mutex_destroy(&source->mutex);
    free(source->socket_path);
}
