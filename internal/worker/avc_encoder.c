#include "avc_encoder.h"

static void clear_outputs(const uint8_t **output, size_t *output_length,
                          int64_t *output_pts)
{
    if (output) *output = NULL;
    if (output_length) *output_length = 0;
    if (output_pts) *output_pts = -1;
}

#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>

#define AVC_READY_CAPACITY 8u

struct rdp_avc_encoder {
    AVCodecContext *codec;
    AVBSFContext *annexb;
    AVFrame *bgra;
    AVFrame *nv12;
    AVPacket *packet;
    AVPacket *filtered;
    AVPacket *output;
    AVPacket *ready[AVC_READY_CAPACITY];
    unsigned ready_head;
    unsigned ready_count;
    struct SwsContext *sws;
    int width, height;
    int64_t next_pts;
    uint64_t codec_packets_received;
    int flush_started;
    int codec_flush_sent;
    int codec_eof;
    int filter_flush_sent;
    int filter_eof;
};

void rdp_avc_encoder_destroy(rdp_avc_encoder *e)
{
    if (!e) return;
    for (unsigned i = 0; i < AVC_READY_CAPACITY; i++)
        av_packet_free(&e->ready[i]);
    av_packet_free(&e->output);
    av_packet_free(&e->filtered);
    av_packet_free(&e->packet);
    av_frame_free(&e->nv12);
    av_frame_free(&e->bgra);
    sws_freeContext(e->sws);
    av_bsf_free(&e->annexb);
    avcodec_free_context(&e->codec);
    free(e);
}

static AVFrame *owned_frame(int width, int height, enum AVPixelFormat format)
{
    AVFrame *frame = av_frame_alloc();
    if (!frame) return NULL;
    frame->width = width;
    frame->height = height;
    frame->format = format;
    if (av_frame_get_buffer(frame, 32) < 0) {
        av_frame_free(&frame);
        return NULL;
    }
    return frame;
}

rdp_avc_encoder *rdp_avc_encoder_create(int width, int height, int fps, int bitrate)
{
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1) ||
        width > 8192 || height > 8192 ||
        (size_t)width * (size_t)height > 33554432 ||
        fps <= 0 || fps > 240 || bitrate <= 0)
        return NULL;
    const AVCodec *codec = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (!codec) return NULL; /* Deliberately no software encoder fallback. */
    rdp_avc_encoder *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->width = width;
    e->height = height;
    e->codec = avcodec_alloc_context3(codec);
    if (!e->codec) goto fail;
    AVCodecContext *c = e->codec;
    c->width = width;
    c->height = height;
    c->pix_fmt = AV_PIX_FMT_NV12;
    c->time_base = (AVRational){1, fps};
    c->framerate = (AVRational){fps, 1};
    c->bit_rate = bitrate;
    c->gop_size = fps;
    c->max_b_frames = 0;
    c->thread_count = 1;
    /* Keep in-band headers: VideoToolbox packets are Annex B and the filter
     * does not manufacture SPS/PPS from absent global extradata. */
    c->flags |= AV_CODEC_FLAG_LOW_DELAY;
    c->color_range = AVCOL_RANGE_MPEG;
    c->colorspace = AVCOL_SPC_BT709;
    c->color_primaries = AVCOL_PRI_BT709;
    c->color_trc = AVCOL_TRC_BT709;
    /* Fail closed if this FFmpeg cannot enforce hardware-only operation. */
    if (av_opt_set_int(c->priv_data, "allow_sw", 0, 0) < 0 ||
        av_opt_set_int(c->priv_data, "require_sw", 0, 0) < 0 ||
        av_opt_set_int(c->priv_data, "realtime", 1, 0) < 0 ||
        av_opt_set(c->priv_data, "profile", "baseline", 0) < 0 ||
        avcodec_open2(c, codec, NULL) < 0)
        goto fail;
    const AVBitStreamFilter *filter = av_bsf_get_by_name("h264_mp4toannexb");
    if (!filter || av_bsf_alloc(filter, &e->annexb) < 0 ||
        avcodec_parameters_from_context(e->annexb->par_in, c) < 0)
        goto fail;
    e->annexb->time_base_in = c->time_base;
    if (av_bsf_init(e->annexb) < 0) goto fail;
    e->packet = av_packet_alloc();
    e->filtered = av_packet_alloc();
    e->output = av_packet_alloc();
    e->bgra = owned_frame(width, height, AV_PIX_FMT_BGRA);
    e->nv12 = owned_frame(width, height, AV_PIX_FMT_NV12);
    if (!e->packet || !e->filtered || !e->output || !e->bgra || !e->nv12)
        goto fail;
    for (unsigned i = 0; i < AVC_READY_CAPACITY; i++) {
        e->ready[i] = av_packet_alloc();
        if (!e->ready[i]) goto fail;
    }
    e->nv12->color_range = c->color_range;
    e->nv12->colorspace = c->colorspace;
    e->nv12->color_primaries = c->color_primaries;
    e->nv12->color_trc = c->color_trc;
    e->sws = sws_getContext(width, height, AV_PIX_FMT_BGRA,
                            width, height, AV_PIX_FMT_NV12,
                            SWS_BILINEAR, NULL, NULL, NULL);
    if (!e->sws) goto fail;
    /* BGRA input is full-range RGB; the AVC output is limited-range BT.709.
     * Do not let swscale silently use its SD/BT.601 default matrix. */
    const int *bt709 = sws_getCoefficients(SWS_CS_ITU709);
    if (!bt709 || sws_setColorspaceDetails(e->sws, bt709, 1, bt709, 0,
                                           0, 1 << 16, 1 << 16) < 0)
        goto fail;
    return e;
fail:
    rdp_avc_encoder_destroy(e);
    return NULL;
}

static int queue_filtered_packet(rdp_avc_encoder *e)
{
    if (e->filtered->size <= 0 || e->filtered->pts == AV_NOPTS_VALUE ||
        e->ready_count >= AVC_READY_CAPACITY)
        return -1;
    unsigned index = (e->ready_head + e->ready_count) % AVC_READY_CAPACITY;
    av_packet_move_ref(e->ready[index], e->filtered);
    e->ready_count++;
    return 0;
}

/* Drain every currently available packet. Return 0 at EAGAIN/EOF, -1 on error. */
static int drain_filter(rdp_avc_encoder *e)
{
    while (e->ready_count < AVC_READY_CAPACITY && !e->filter_eof) {
        int rc = av_bsf_receive_packet(e->annexb, e->filtered);
        if (rc == AVERROR(EAGAIN)) return 0;
        if (rc == AVERROR_EOF) {
            e->filter_eof = 1;
            return 0;
        }
        if (rc < 0 || queue_filtered_packet(e) < 0) return -1;
    }
    return 0;
}

/* Send the same still-owned packet again after draining an EAGAIN filter. */
static int send_to_filter(rdp_avc_encoder *e, AVPacket *packet)
{
    for (;;) {
        unsigned before = e->ready_count;
        int rc = av_bsf_send_packet(e->annexb, packet);
        if (rc == AVERROR(EAGAIN)) {
            if (drain_filter(e) < 0 || e->ready_count == before) return -1;
            continue;
        }
        if (rc < 0) return -1;
        return drain_filter(e);
    }
}

/* Pull all available codec packets and feed each through the Annex-B filter. */
static int drain_codec(rdp_avc_encoder *e)
{
    while (e->ready_count < AVC_READY_CAPACITY && !e->codec_eof) {
        int rc = avcodec_receive_packet(e->codec, e->packet);
        if (rc == AVERROR(EAGAIN)) return 0;
        if (rc == AVERROR_EOF) {
            e->codec_eof = 1;
            return 0;
        }
        if (rc < 0) return -1;
        e->codec_packets_received++;
        if (send_to_filter(e, e->packet) < 0) {
            av_packet_unref(e->packet);
            return -1;
        }
        av_packet_unref(e->packet);
    }
    return 0;
}

static int take_output(rdp_avc_encoder *e, const uint8_t **output,
                       size_t *output_length, int64_t *output_pts)
{
    if (!e->ready_count) return 0;
    AVPacket *packet = e->ready[e->ready_head];
    if (packet->size <= 0 || packet->pts == AV_NOPTS_VALUE) return -1;
    av_packet_move_ref(e->output, packet);
    e->ready_head = (e->ready_head + 1) % AVC_READY_CAPACITY;
    e->ready_count--;
    *output = e->output->data;
    *output_length = (size_t)e->output->size;
    *output_pts = e->output->pts;
    return 1;
}

int rdp_avc_encoder_encode(rdp_avc_encoder *e, const uint8_t *bgra,
                           size_t bgra_length, size_t stride,
                           const uint8_t **output, size_t *output_length,
                           int64_t *output_pts)
{
    clear_outputs(output, output_length, output_pts);
    if (e) av_packet_unref(e->output);
    if (!e || !bgra || !output || !output_length || !output_pts ||
        e->flush_started || e->next_pts == INT64_MAX)
        return -1;
    size_t row = (size_t)e->width * 4;
    size_t rows_before_last = (size_t)e->height - 1;
    if (stride < row || stride > INT_MAX ||
        rows_before_last > (SIZE_MAX - row) / stride ||
        bgra_length < rows_before_last * stride + row ||
        av_frame_make_writable(e->bgra) < 0 ||
        av_frame_make_writable(e->nv12) < 0)
        return -1;
    for (int y = 0; y < e->height; y++)
        memcpy(e->bgra->data[0] + (size_t)y * e->bgra->linesize[0],
               bgra + (size_t)y * stride, row);
    if (sws_scale(e->sws, (const uint8_t * const *)e->bgra->data,
                  e->bgra->linesize, 0, e->height,
                  e->nv12->data, e->nv12->linesize) != e->height)
        return -1;
    e->nv12->pts = e->next_pts;
    e->nv12->pict_type = AV_PICTURE_TYPE_NONE;

    for (;;) {
        int rc = avcodec_send_frame(e->codec, e->nv12);
        if (rc == AVERROR(EAGAIN)) {
            uint64_t before = e->codec_packets_received;
            if (drain_codec(e) < 0 || e->codec_packets_received == before)
                return -1;
            continue; /* EAGAIN does not consume nv12; retry identical frame. */
        }
        if (rc < 0) return -1;
        e->next_pts++;
        break;
    }
    if (drain_codec(e) < 0) return -1;
    return take_output(e, output, output_length, output_pts);
}

int rdp_avc_encoder_flush(rdp_avc_encoder *e, const uint8_t **output,
                          size_t *output_length, int64_t *output_pts)
{
    clear_outputs(output, output_length, output_pts);
    if (!e || !output || !output_length || !output_pts) return -1;
    av_packet_unref(e->output);
    e->flush_started = 1;
    int rc = take_output(e, output, output_length, output_pts);
    if (rc != 0) return rc;

    while (!e->codec_flush_sent && !e->codec_eof) {
        int send = avcodec_send_frame(e->codec, NULL);
        if (send == AVERROR(EAGAIN)) {
            uint64_t before = e->codec_packets_received;
            if (drain_codec(e) < 0) return -1;
            rc = take_output(e, output, output_length, output_pts);
            if (rc != 0) return rc;
            if (e->codec_packets_received == before) return -1;
            continue;
        }
        if (send == AVERROR_EOF) {
            e->codec_eof = 1;
            break;
        }
        if (send < 0) return -1;
        e->codec_flush_sent = 1;
    }
    if (drain_codec(e) < 0) return -1;
    rc = take_output(e, output, output_length, output_pts);
    if (rc != 0) return rc;
    if (!e->codec_eof) return -1;

    while (!e->filter_flush_sent && !e->filter_eof) {
        unsigned before = e->ready_count;
        int send = av_bsf_send_packet(e->annexb, NULL);
        if (send == AVERROR(EAGAIN)) {
            if (drain_filter(e) < 0) return -1;
            rc = take_output(e, output, output_length, output_pts);
            if (rc != 0) return rc;
            if (e->ready_count == before) return -1;
            continue;
        }
        if (send == AVERROR_EOF) {
            e->filter_eof = 1;
            break;
        }
        if (send < 0) return -1;
        e->filter_flush_sent = 1;
    }
    if (drain_filter(e) < 0) return -1;
    rc = take_output(e, output, output_length, output_pts);
    if (rc != 0) return rc;
    return e->filter_eof ? 0 : -1;
}

#else

rdp_avc_encoder *rdp_avc_encoder_create(int width, int height, int fps, int bitrate)
{
    (void)width; (void)height; (void)fps; (void)bitrate;
    return NULL;
}

int rdp_avc_encoder_encode(rdp_avc_encoder *encoder, const uint8_t *bgra,
                           size_t bgra_length, size_t stride,
                           const uint8_t **output, size_t *output_length,
                           int64_t *output_pts)
{
    (void)encoder; (void)bgra; (void)bgra_length; (void)stride;
    clear_outputs(output, output_length, output_pts);
    return -1;
}

int rdp_avc_encoder_flush(rdp_avc_encoder *encoder, const uint8_t **output,
                          size_t *output_length, int64_t *output_pts)
{
    (void)encoder;
    clear_outputs(output, output_length, output_pts);
    return -1;
}

void rdp_avc_encoder_destroy(rdp_avc_encoder *encoder)
{
    (void)encoder;
}

#endif
