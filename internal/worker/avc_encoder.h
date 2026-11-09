#ifndef RDP_AVC_ENCODER_H
#define RDP_AVC_ENCODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rdp_avc_encoder rdp_avc_encoder;

/* Optional hardware-only encoder. Without RDP_WITH_FFMPEG=1 create returns NULL.
 * Dimensions must be positive/even, at most 8192 each and 33554432 pixels total;
 * fps is 1..240 and bitrate is 1..INT_MAX bits/second. NULL means unavailable
 * hardware, unsupported settings, invalid arguments, or allocation failure. */
rdp_avc_encoder *rdp_avc_encoder_create(int width, int height, int fps, int bitrate);

/* Submit one top-down BGRA frame. stride is bytes per row (positive, <= INT_MAX);
 * bgra_length must cover (height-1)*stride + width*4, including row padding.
 * Caller memory is never retained. Returns 1 with an Annex B access unit,
 * 0 when the accepted frame has no output yet, or -1 on error. output_pts
 * identifies the actual source frame of each packet, including delayed output.
 * On 0/-1, outputs are NULL/0 and output_pts is -1. Send-side EAGAIN is
 * drained and the same input is retried internally; it is not consumed twice.
 * Output belongs to this encoder, valid until its next API call or destroy.
 * Call flush repeatedly after the final frame: it returns 1 per delayed access
 * unit, then 0 only after codec and filter EOF; -1 means drain failure.
 * No frame may be submitted after flushing starts, even if flush returned a packet.
 * Each instance is single-thread-use; independent instances share no buffers. */
int rdp_avc_encoder_encode(rdp_avc_encoder *encoder, const uint8_t *bgra,
                           size_t bgra_length, size_t stride,
                           const uint8_t **output, size_t *output_length,
                           int64_t *output_pts);
int rdp_avc_encoder_flush(rdp_avc_encoder *encoder, const uint8_t **output,
                          size_t *output_length, int64_t *output_pts);
void rdp_avc_encoder_destroy(rdp_avc_encoder *encoder);

#ifdef __cplusplus
}
#endif
#endif
