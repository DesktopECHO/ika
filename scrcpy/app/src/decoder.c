#include "decoder.h"

#include <errno.h>
#include <libavcodec/packet.h>
#include <libavutil/avutil.h>

#include "util/log.h"

/** Downcast packet_sink to decoder */
#define DOWNCAST(SINK) container_of(SINK, struct sc_decoder, packet_sink)

static bool
sc_decoder_open(struct sc_decoder *decoder, AVCodecContext *ctx,
                const struct sc_stream_session *session) {
    decoder->frame = av_frame_alloc();
    if (!decoder->frame) {
        LOG_OOM();
        return false;
    }

    if (!sc_frame_source_sinks_open(&decoder->frame_source, ctx, session)) {
        av_frame_free(&decoder->frame);
        return false;
    }

    decoder->ctx = ctx;
    decoder->own_ctx = NULL;

    // A video stream must have a session
    assert(session || ctx->codec_type != AVMEDIA_TYPE_VIDEO);

    if (session) {
        decoder->session = *session;
    }

    memset(&decoder->frame_size, 0, sizeof(decoder->frame_size));

    return true;
}

static void
sc_decoder_close(struct sc_decoder *decoder) {
    sc_frame_source_sinks_close(&decoder->frame_source);
    av_frame_free(&decoder->frame);
    avcodec_free_context(&decoder->own_ctx);
}

static bool
sc_decoder_push(struct sc_decoder *decoder, const AVPacket *packet) {
    bool is_config = packet->pts == AV_NOPTS_VALUE;
    if (is_config) {
        // nothing to do
        return true;
    }

    int ret = avcodec_send_packet(decoder->ctx, packet);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
        LOGE("Decoder '%s': could not send video packet: %d",
             decoder->name, ret);
        return false;
    }

    for (;;) {
        ret = avcodec_receive_frame(decoder->ctx, decoder->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }

        if (ret) {
            LOGE("Decoder '%s', could not receive video frame: %d",
                 decoder->name, ret);
            return false;
        }

        // a frame was received

        if (decoder->ctx->codec_type == AVMEDIA_TYPE_VIDEO) {
            assert(decoder->frame->width >= 0);
            assert(decoder->frame->height >= 0);
            struct sc_size frame_size = {
                .width = decoder->frame->width,
                .height = decoder->frame->height,
            };
            if (decoder->frame_size.width != frame_size.width
                    || decoder->frame_size.height != frame_size.height) {
                // The frame size has changed, check if it matches the session
                uint32_t sw = decoder->session.video.width;
                uint32_t sh = decoder->session.video.height;
                if (frame_size.width != sw || frame_size.height != sh) {
                    LOGW("Unexpected video size: %" PRIu32 "x%" PRIu32
                         " (expected %" PRIu32 "x%" PRIu32 ")",
                         frame_size.width, frame_size.height, sw, sh);

                    LOGW("The encoder did not respect the requested size, "
                         "please retry with a lower resolution (-m/--max-size)");
                }
            }

            decoder->frame_size = frame_size;
        }

        bool ok = sc_frame_source_sinks_push(&decoder->frame_source,
                                             decoder->frame);
        av_frame_unref(decoder->frame);
        if (!ok) {
            // Error already logged
            return false;
        }
    }

    return true;
}

// Decode a session of a new video size with a fresh context. FFmpeg's H.264
// decoder only reinitializes when the macroblock grid changes, so a resize
// within the same grid (898x1348 -> 900x1350: 57x85 macroblocks either way)
// kept the previous size. The frames then disagreed with the server's video
// size, which ignores mouse events generated for another size.
static bool
sc_decoder_reopen(struct sc_decoder *decoder,
                  const struct sc_stream_session *session) {
    const AVCodec *codec = decoder->ctx->codec;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        LOG_OOM();
        return false;
    }

    ctx->flags = decoder->ctx->flags;
    ctx->width = session->video.width;
    ctx->height = session->video.height;
    ctx->pix_fmt = decoder->ctx->pix_fmt;

    if (avcodec_open2(ctx, codec, NULL) < 0) {
        LOGE("Decoder '%s': could not reopen codec", decoder->name);
        avcodec_free_context(&ctx);
        return false;
    }

    avcodec_free_context(&decoder->own_ctx);
    decoder->own_ctx = ctx;
    decoder->ctx = ctx;
    return true;
}

static bool
sc_decoder_push_session(struct sc_decoder *decoder,
                        const struct sc_stream_session *session) {
    // A new session starts with a key frame, so nothing is lost by switching
    // to a new context
    if (decoder->ctx->codec_type == AVMEDIA_TYPE_VIDEO
            && (session->video.width != decoder->session.video.width
                || session->video.height != decoder->session.video.height)
            && !sc_decoder_reopen(decoder, session)) {
        return false;
    }

    decoder->session = *session;
    return sc_frame_source_sinks_push_session(&decoder->frame_source, session);
}

static bool
sc_decoder_packet_sink_open(struct sc_packet_sink *sink, AVCodecContext *ctx,
                            const struct sc_stream_session *session) {
    struct sc_decoder *decoder = DOWNCAST(sink);
    return sc_decoder_open(decoder, ctx, session);
}

static void
sc_decoder_packet_sink_close(struct sc_packet_sink *sink) {
    struct sc_decoder *decoder = DOWNCAST(sink);
    sc_decoder_close(decoder);
}

static bool
sc_decoder_packet_sink_push(struct sc_packet_sink *sink,
                            const AVPacket *packet) {
    struct sc_decoder *decoder = DOWNCAST(sink);
    return sc_decoder_push(decoder, packet);
}

static bool
sc_decoder_packet_sink_push_session(struct sc_packet_sink *sink,
                                    const struct sc_stream_session *session) {

    struct sc_decoder *decoder = DOWNCAST(sink);
    return sc_decoder_push_session(decoder, session);
}

void
sc_decoder_init(struct sc_decoder *decoder, const char *name) {
    decoder->name = name; // statically allocated
    sc_frame_source_init(&decoder->frame_source);

    static const struct sc_packet_sink_ops ops = {
        .open = sc_decoder_packet_sink_open,
        .close = sc_decoder_packet_sink_close,
        .push = sc_decoder_packet_sink_push,
        .push_session = sc_decoder_packet_sink_push_session,
    };

    decoder->packet_sink.ops = &ops;
}
