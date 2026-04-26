#include "cuttlefish_frame_source.h"

#include <errno.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>

#include "events.h"
#include "util/log.h"

#ifndef _WIN32
# include <sys/mman.h>
# include <sys/socket.h>
# include <sys/un.h>
# include <unistd.h>
#endif

#define SC_CUTTLEFISH_FRAME_MAGIC 0x46414b49u
#define SC_CUTTLEFISH_FRAME_VERSION 1
#define SC_CUTTLEFISH_DMABUF_FRAME_MAGIC 0x44414b49u
#define SC_CUTTLEFISH_DMABUF_FRAME_VERSION 1
#define SC_CUTTLEFISH_SHM_INIT_MAGIC 0x53414b49u
#define SC_CUTTLEFISH_SHM_NOTIFY_MAGIC 0x4e414b49u
#define SC_CUTTLEFISH_SHM_FRAME_VERSION 1
#define SC_CUTTLEFISH_FRAME_MAX_PAYLOAD (256u * 1024u * 1024u)

#define SC_FOURCC(a, b, c, d) \
    ((uint32_t) (a) | ((uint32_t) (b) << 8) | ((uint32_t) (c) << 16) \
        | ((uint32_t) (d) << 24))

#define SC_DRM_FORMAT_XRGB8888 SC_FOURCC('X', 'R', '2', '4')
#define SC_DRM_FORMAT_XBGR8888 SC_FOURCC('X', 'B', '2', '4')
#define SC_DRM_FORMAT_RGBX8888 SC_FOURCC('R', 'X', '2', '4')
#define SC_DRM_FORMAT_BGRX8888 SC_FOURCC('B', 'X', '2', '4')
#define SC_DRM_FORMAT_ARGB8888 SC_FOURCC('A', 'R', '2', '4')
#define SC_DRM_FORMAT_ABGR8888 SC_FOURCC('A', 'B', '2', '4')
#define SC_DRM_FORMAT_RGBA8888 SC_FOURCC('R', 'A', '2', '4')
#define SC_DRM_FORMAT_BGRA8888 SC_FOURCC('B', 'A', '2', '4')

struct sc_cuttlefish_raw_frame_header {
    uint32_t magic;
    uint32_t version;
    uint32_t display_number;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t stride_bytes;
    uint32_t payload_size;
};

struct sc_cuttlefish_dmabuf_frame_header {
    uint32_t magic;
    uint32_t version;
    uint32_t display_number;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t offset;
    uint32_t stride_bytes;
    uint32_t modifier_hi;
    uint32_t modifier_lo;
};

struct sc_cuttlefish_shm_init_header {
    uint32_t magic;
    uint32_t version;
    uint32_t slot_count;
    uint32_t slot_size;
};

struct sc_cuttlefish_shm_notify_header {
    uint32_t magic;
    uint32_t version;
    uint32_t display_number;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t stride_bytes;
    uint32_t payload_size;
    uint32_t slot_index;
};

struct sc_cuttlefish_frame_common_header {
    uint32_t magic;
    uint32_t version;
};

static char *
sc_strdup(const char *s) {
    size_t len = strlen(s) + 1;
    char *copy = malloc(len);
    if (!copy) {
        return NULL;
    }
    memcpy(copy, s, len);
    return copy;
}

static bool
sc_cuttlefish_frame_source_is_stopped(struct sc_cuttlefish_frame_source *source) {
    sc_mutex_lock(&source->mutex);
    bool stopped = source->stopped;
    sc_mutex_unlock(&source->mutex);
    return stopped;
}

static void
sc_cuttlefish_frame_source_set_socket(struct sc_cuttlefish_frame_source *source,
                                      int fd) {
    sc_mutex_lock(&source->mutex);
    source->socket_fd = fd;
    sc_mutex_unlock(&source->mutex);
}

static const char *
sc_fourcc_to_string(uint32_t fourcc, char buf[5]) {
    buf[0] = fourcc & 0xff;
    buf[1] = (fourcc >> 8) & 0xff;
    buf[2] = (fourcc >> 16) & 0xff;
    buf[3] = (fourcc >> 24) & 0xff;
    buf[4] = '\0';
    return buf;
}

static SDL_PixelFormat
sc_cuttlefish_fourcc_to_sdl_format(uint32_t fourcc) {
    switch (fourcc) {
        case SC_DRM_FORMAT_XRGB8888:
            return SDL_PIXELFORMAT_XRGB8888;
        case SC_DRM_FORMAT_XBGR8888:
            return SDL_PIXELFORMAT_XBGR8888;
        case SC_DRM_FORMAT_RGBX8888:
            return SDL_PIXELFORMAT_RGBX8888;
        case SC_DRM_FORMAT_BGRX8888:
            return SDL_PIXELFORMAT_BGRX8888;
        case SC_DRM_FORMAT_ARGB8888:
            return SDL_PIXELFORMAT_ARGB8888;
        case SC_DRM_FORMAT_ABGR8888:
            return SDL_PIXELFORMAT_ABGR8888;
        case SC_DRM_FORMAT_RGBA8888:
            return SDL_PIXELFORMAT_RGBA8888;
        case SC_DRM_FORMAT_BGRA8888:
            return SDL_PIXELFORMAT_BGRA8888;
        default:
            return SDL_PIXELFORMAT_UNKNOWN;
    }
}

#ifndef _WIN32
static bool
sc_recv_common_header(int fd, struct sc_cuttlefish_frame_common_header *header,
                      int *received_fd) {
    *received_fd = -1;

    struct iovec iov = {
        .iov_base = header,
        .iov_len = sizeof(*header),
    };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    ssize_t r;
    do {
        r = recvmsg(fd, &msg, MSG_WAITALL);
    } while (r < 0 && errno == EINTR);

    if (r != (ssize_t) sizeof(*header)) {
        return false;
    }

    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg;
            cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET
                && cmsg->cmsg_type == SCM_RIGHTS
                && cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
            memcpy(received_fd, CMSG_DATA(cmsg), sizeof(int));
            break;
        }
    }

    return true;
}

static bool
sc_read_all(int fd, void *buf, size_t size) {
    char *ptr = buf;
    while (size) {
        ssize_t r = read(fd, ptr, size);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (!r) {
            return false;
        }
        ptr += r;
        size -= r;
    }
    return true;
}

static bool
sc_read_remaining_header(int fd, void *header, size_t header_size) {
    assert(header_size >= sizeof(struct sc_cuttlefish_frame_common_header));
    char *ptr = header;
    return sc_read_all(fd, ptr + sizeof(struct sc_cuttlefish_frame_common_header),
                       header_size
                           - sizeof(struct sc_cuttlefish_frame_common_header));
}

static bool
sc_discard_all(int fd, size_t size) {
    char buf[4096];
    while (size) {
        size_t count = size < sizeof(buf) ? size : sizeof(buf);
        if (!sc_read_all(fd, buf, count)) {
            return false;
        }
        size -= count;
    }
    return true;
}

static void
sc_cuttlefish_frame_source_unmap_shm(
        struct sc_cuttlefish_frame_source *source) {
    if (source->shm_data) {
        munmap(source->shm_data, source->shm_size);
        source->shm_data = NULL;
    }
    source->shm_size = 0;
    source->shm_slot_count = 0;
    source->shm_slot_size = 0;
}

static bool
sc_cuttlefish_handle_shm_init(struct sc_cuttlefish_frame_source *source,
                              int fd,
                              const struct sc_cuttlefish_frame_common_header *c,
                              int received_fd) {
    struct sc_cuttlefish_shm_init_header header;
    memcpy(&header, c, sizeof(*c));
    if (!sc_read_remaining_header(fd, &header, sizeof(header))) {
        if (received_fd >= 0) {
            close(received_fd);
        }
        return false;
    }

    if (header.magic != SC_CUTTLEFISH_SHM_INIT_MAGIC
            || header.version != SC_CUTTLEFISH_SHM_FRAME_VERSION
            || !header.slot_count || header.slot_count > 16
            || !header.slot_size
            || header.slot_size > SC_CUTTLEFISH_FRAME_MAX_PAYLOAD
            || received_fd < 0) {
        LOGE("Invalid Cuttlefish shared raw frame setup");
        if (received_fd >= 0) {
            close(received_fd);
        }
        return false;
    }

    size_t shm_size = (size_t) header.slot_count * header.slot_size;
    if (shm_size / header.slot_count != header.slot_size) {
        LOGE("Invalid Cuttlefish shared raw frame size");
        close(received_fd);
        return false;
    }

    uint8_t *data = mmap(NULL, shm_size, PROT_READ, MAP_SHARED, received_fd, 0);
    close(received_fd);
    if (data == MAP_FAILED) {
        LOGE("Could not map Cuttlefish raw frame shared memory: %s",
             strerror(errno));
        return false;
    }

    sc_cuttlefish_frame_source_unmap_shm(source);
    source->shm_data = data;
    source->shm_size = shm_size;
    source->shm_slot_count = header.slot_count;
    source->shm_slot_size = header.slot_size;

    LOGI("Using Cuttlefish shared raw frame slots: %" PRIu32 " x %" PRIu32,
         header.slot_count, header.slot_size);
    return true;
}

static bool
sc_cuttlefish_validate_dmabuf_frame(
        const struct sc_cuttlefish_dmabuf_frame_header *h,
        SDL_PixelFormat format, int dmabuf_fd) {
    if (h->magic != SC_CUTTLEFISH_DMABUF_FRAME_MAGIC
            || h->version != SC_CUTTLEFISH_DMABUF_FRAME_VERSION) {
        LOGE("Invalid Cuttlefish DMA-BUF frame stream header");
        return false;
    }
    if (!h->width || h->width > 0xffff || !h->height || h->height > 0xffff
            || !h->stride_bytes || dmabuf_fd < 0) {
        LOGE("Invalid Cuttlefish DMA-BUF frame dimensions");
        return false;
    }
    if (format == SDL_PIXELFORMAT_UNKNOWN) {
        char fourcc[5];
        LOGE("Unsupported Cuttlefish DMA-BUF frame format: %s",
             sc_fourcc_to_string(h->fourcc, fourcc));
        return false;
    }

    uint32_t bpp = SDL_BYTESPERPIXEL(format);
    if (!bpp || h->width > UINT32_MAX / bpp) {
        LOGE("Invalid Cuttlefish DMA-BUF frame pixel format");
        return false;
    }
    uint32_t min_stride = h->width * bpp;
    if (h->stride_bytes < min_stride) {
        LOGE("Invalid Cuttlefish DMA-BUF frame stride");
        return false;
    }
    return true;
}

static bool
sc_cuttlefish_validate_shm_frame(
        const struct sc_cuttlefish_frame_source *source,
        const struct sc_cuttlefish_shm_notify_header *h,
        SDL_PixelFormat format) {
    if (h->magic != SC_CUTTLEFISH_SHM_NOTIFY_MAGIC
            || h->version != SC_CUTTLEFISH_SHM_FRAME_VERSION) {
        LOGE("Invalid Cuttlefish shared raw frame header");
        return false;
    }
    if (!source->shm_data || !source->shm_slot_count || !source->shm_slot_size
            || h->slot_index >= source->shm_slot_count
            || !h->width || h->width > 0xffff
            || !h->height || h->height > 0xffff
            || !h->stride_bytes || !h->payload_size
            || h->payload_size > source->shm_slot_size) {
        LOGE("Invalid Cuttlefish shared raw frame dimensions");
        return false;
    }
    if (format == SDL_PIXELFORMAT_UNKNOWN) {
        char fourcc[5];
        LOGE("Unsupported Cuttlefish shared raw frame format: %s",
             sc_fourcc_to_string(h->fourcc, fourcc));
        return false;
    }

    uint32_t bpp = SDL_BYTESPERPIXEL(format);
    if (!bpp || h->width > UINT32_MAX / bpp) {
        LOGE("Invalid Cuttlefish shared raw frame pixel format");
        return false;
    }
    uint32_t min_stride = h->width * bpp;
    if (h->stride_bytes < min_stride) {
        LOGE("Invalid Cuttlefish shared raw frame stride");
        return false;
    }
    if (h->height > UINT32_MAX / h->stride_bytes
            || h->payload_size < h->height * h->stride_bytes) {
        LOGE("Invalid Cuttlefish shared raw frame payload size");
        return false;
    }
    return true;
}

static bool
sc_cuttlefish_validate_frame(const struct sc_cuttlefish_raw_frame_header *h,
                             SDL_PixelFormat format) {
    if (h->magic != SC_CUTTLEFISH_FRAME_MAGIC
            || h->version != SC_CUTTLEFISH_FRAME_VERSION) {
        LOGE("Invalid Cuttlefish raw frame stream header");
        return false;
    }
    if (!h->width || h->width > 0xffff || !h->height || h->height > 0xffff
            || !h->stride_bytes || !h->payload_size
            || h->payload_size > SC_CUTTLEFISH_FRAME_MAX_PAYLOAD) {
        LOGE("Invalid Cuttlefish raw frame dimensions");
        return false;
    }
    if (format == SDL_PIXELFORMAT_UNKNOWN) {
        char fourcc[5];
        LOGE("Unsupported Cuttlefish raw frame format: %s",
             sc_fourcc_to_string(h->fourcc, fourcc));
        return false;
    }

    uint32_t bpp = SDL_BYTESPERPIXEL(format);
    if (!bpp || h->width > UINT32_MAX / bpp) {
        LOGE("Invalid Cuttlefish raw frame pixel format");
        return false;
    }
    uint32_t min_stride = h->width * bpp;
    if (h->stride_bytes < min_stride) {
        LOGE("Invalid Cuttlefish raw frame stride");
        return false;
    }
    if (h->height > UINT32_MAX / h->stride_bytes
            || h->payload_size < h->height * h->stride_bytes) {
        LOGE("Invalid Cuttlefish raw frame payload size");
        return false;
    }
    return true;
}

static int
sc_cuttlefish_connect(const char *socket_path) {
    if (strlen(socket_path) >= sizeof(((struct sockaddr_un *) 0)->sun_path)) {
        LOGE("Cuttlefish frame socket path is too long: %s", socket_path);
        return -1;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd == -1) {
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, socket_path);

    if (connect(fd, (const struct sockaddr *) &addr, sizeof(addr)) == -1) {
        close(fd);
        return -1;
    }

    return fd;
}

static int
run_cuttlefish_frame_source(void *data) {
    struct sc_cuttlefish_frame_source *source = data;
    bool connect_error_logged = false;

    while (!sc_cuttlefish_frame_source_is_stopped(source)) {
        int fd = sc_cuttlefish_connect(source->socket_path);
        if (fd == -1) {
            if (!connect_error_logged) {
                LOGW("Could not connect to Cuttlefish frame socket %s: %s",
                     source->socket_path, strerror(errno));
                connect_error_logged = true;
            }
            SDL_Delay(100);
            continue;
        }

        connect_error_logged = false;
        sc_cuttlefish_frame_source_set_socket(source, fd);
        LOGI("Connected to Cuttlefish frame socket %s", source->socket_path);

        while (!sc_cuttlefish_frame_source_is_stopped(source)) {
            struct sc_cuttlefish_frame_common_header common_header;
            int received_fd;
            if (!sc_recv_common_header(fd, &common_header, &received_fd)) {
                break;
            }

            if (common_header.magic == SC_CUTTLEFISH_FRAME_MAGIC) {
                if (received_fd >= 0) {
                    close(received_fd);
                    received_fd = -1;
                }

                struct sc_cuttlefish_raw_frame_header header;
                memcpy(&header, &common_header, sizeof(common_header));
                if (!sc_read_remaining_header(fd, &header, sizeof(header))) {
                    break;
                }

                SDL_PixelFormat format =
                    sc_cuttlefish_fourcc_to_sdl_format(header.fourcc);
                if (!sc_cuttlefish_validate_frame(&header, format)) {
                    break;
                }

                if (header.display_number != source->display_id) {
                    if (!sc_discard_all(fd, header.payload_size)) {
                        break;
                    }
                    continue;
                }

                uint8_t *payload =
                    sc_screen_alloc_raw_frame_buffer(source->screen,
                                                     header.payload_size);
                if (!payload) {
                    LOG_OOM();
                    break;
                }

                bool ok = sc_read_all(fd, payload, header.payload_size);
                if (ok) {
                    uint8_t *frame_payload = payload;
                    payload = NULL;
                    ok = sc_screen_push_raw_frame(source->screen,
                                                 header.display_number,
                                                 header.width, header.height,
                                                 header.fourcc, format,
                                                 header.stride_bytes,
                                                 frame_payload,
                                                 header.payload_size, true);
                }
                if (payload) {
                    sc_screen_recycle_raw_frame_buffer(source->screen, payload,
                                                       header.payload_size);
                }

                if (!ok) {
                    break;
                }
            } else if (common_header.magic == SC_CUTTLEFISH_DMABUF_FRAME_MAGIC) {
                struct sc_cuttlefish_dmabuf_frame_header header;
                memcpy(&header, &common_header, sizeof(common_header));
                if (!sc_read_remaining_header(fd, &header, sizeof(header))) {
                    if (received_fd >= 0) {
                        close(received_fd);
                    }
                    break;
                }

                SDL_PixelFormat format =
                    sc_cuttlefish_fourcc_to_sdl_format(header.fourcc);
                if (!sc_cuttlefish_validate_dmabuf_frame(&header, format,
                                                         received_fd)) {
                    if (received_fd >= 0) {
                        close(received_fd);
                    }
                    break;
                }

                if (header.display_number != source->display_id) {
                    close(received_fd);
                    continue;
                }

                int frame_fd = received_fd;
                received_fd = -1;
                bool ok = sc_screen_push_dmabuf_frame(
                    source->screen, header.display_number, header.width,
                    header.height, header.fourcc, format, frame_fd,
                    header.offset, header.stride_bytes, header.modifier_hi,
                    header.modifier_lo);
                if (!ok) {
                    break;
                }
            } else if (common_header.magic == SC_CUTTLEFISH_SHM_INIT_MAGIC) {
                if (!sc_cuttlefish_handle_shm_init(source, fd, &common_header,
                                                   received_fd)) {
                    break;
                }
            } else if (common_header.magic == SC_CUTTLEFISH_SHM_NOTIFY_MAGIC) {
                if (received_fd >= 0) {
                    close(received_fd);
                    received_fd = -1;
                }

                struct sc_cuttlefish_shm_notify_header header;
                memcpy(&header, &common_header, sizeof(common_header));
                if (!sc_read_remaining_header(fd, &header, sizeof(header))) {
                    break;
                }

                SDL_PixelFormat format =
                    sc_cuttlefish_fourcc_to_sdl_format(header.fourcc);
                if (!sc_cuttlefish_validate_shm_frame(source, &header,
                                                      format)) {
                    break;
                }

                if (header.display_number != source->display_id) {
                    continue;
                }

                uint8_t *payload =
                    sc_screen_alloc_raw_frame_buffer(source->screen,
                                                     header.payload_size);
                if (!payload) {
                    LOG_OOM();
                    break;
                }
                memcpy(payload,
                       source->shm_data
                       + (size_t) header.slot_index * source->shm_slot_size,
                       header.payload_size);
                uint8_t *frame_payload = payload;
                payload = NULL;
                bool ok = sc_screen_push_raw_frame(
                    source->screen, header.display_number, header.width,
                    header.height, header.fourcc, format, header.stride_bytes,
                    frame_payload, header.payload_size, true);
                if (payload) {
                    sc_screen_recycle_raw_frame_buffer(source->screen, payload,
                                                       header.payload_size);
                }
                if (!ok) {
                    break;
                }
            } else {
                if (received_fd >= 0) {
                    close(received_fd);
                }
                LOGE("Invalid Cuttlefish frame stream header");
                break;
            }
        }

        sc_cuttlefish_frame_source_set_socket(source, -1);
        close(fd);
        sc_cuttlefish_frame_source_unmap_shm(source);

        if (!sc_cuttlefish_frame_source_is_stopped(source)) {
            LOGW("Cuttlefish frame socket disconnected; reconnecting");
            SDL_Delay(250);
        }
    }

    return 0;
}
#else
static int
run_cuttlefish_frame_source(void *data) {
    (void) data;
    LOGE("Cuttlefish frame sockets are not supported on Windows");
    sc_push_event(SC_EVENT_DEVICE_DISCONNECTED);
    return 1;
}
#endif

bool
sc_cuttlefish_frame_source_init(struct sc_cuttlefish_frame_source *source,
                                const char *socket_path,
                                uint32_t display_id,
                                struct sc_screen *screen) {
    source->socket_path = sc_strdup(socket_path);
    if (!source->socket_path) {
        LOG_OOM();
        return false;
    }

    bool ok = sc_mutex_init(&source->mutex);
    if (!ok) {
        free(source->socket_path);
        return false;
    }

    source->stopped = false;
    source->socket_fd = -1;
    source->display_id = display_id;
    source->screen = screen;
    source->shm_data = NULL;
    source->shm_size = 0;
    source->shm_slot_count = 0;
    source->shm_slot_size = 0;
    return true;
}

bool
sc_cuttlefish_frame_source_start(struct sc_cuttlefish_frame_source *source) {
    return sc_thread_create(&source->thread, run_cuttlefish_frame_source,
                            "cuttlefish-frame-source", source);
}

void
sc_cuttlefish_frame_source_stop(struct sc_cuttlefish_frame_source *source) {
    sc_mutex_lock(&source->mutex);
    source->stopped = true;
#ifndef _WIN32
    if (source->socket_fd != -1) {
        shutdown(source->socket_fd, SHUT_RDWR);
    }
#endif
    sc_mutex_unlock(&source->mutex);
}

void
sc_cuttlefish_frame_source_join(struct sc_cuttlefish_frame_source *source) {
    sc_thread_join(&source->thread, NULL);
}

void
sc_cuttlefish_frame_source_destroy(struct sc_cuttlefish_frame_source *source) {
#ifndef _WIN32
    sc_cuttlefish_frame_source_unmap_shm(source);
#endif
    free(source->socket_path);
    sc_mutex_destroy(&source->mutex);
}
