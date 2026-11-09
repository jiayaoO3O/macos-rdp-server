/* Peer-thread-only AVC420 capability and bounded acknowledgement policy.
 * No codec, channel, or desktop ownership lives here. An ACK is a protocol
 * acknowledgement, NOT proof of client-rendered FPS or visual quality. */
#ifndef RDP_GFX_SESSION_H
#define RDP_GFX_SESSION_H
#include <freerdp/channels/rdpgfx.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Only accept versions whose AVC flags we understand. Do not infer support
 * from an unknown version number or the core RDP graphics capability alone. */
static inline int rdp_gfx_select_avc420(int enabled, int encoder_ready,
 const RDPGFX_CAPSET *caps, size_t count, RDPGFX_CAPSET *selected) {
 if (!enabled || !encoder_ready || !caps || !count || !selected) return 0;
 RDPGFX_CAPSET best = {0};
 for (size_t i=0; i<count; i++) {
  const RDPGFX_CAPSET *cap=&caps[i];
  if (cap->length<4) continue;
  uint32_t flags=0;
  switch (cap->version) {
   case RDPGFX_CAPVERSION_81:
    if (!(cap->flags & RDPGFX_CAPS_FLAG_AVC420_ENABLED)) continue;
    flags=RDPGFX_CAPS_FLAG_AVC420_ENABLED;
    break;
   case RDPGFX_CAPVERSION_10:
   case RDPGFX_CAPVERSION_102:
   case RDPGFX_CAPVERSION_103:
   case RDPGFX_CAPVERSION_104:
   case RDPGFX_CAPVERSION_105:
   case RDPGFX_CAPVERSION_106:
   case RDPGFX_CAPVERSION_106_ERR:
   case RDPGFX_CAPVERSION_107:
    if (cap->flags & RDPGFX_CAPS_FLAG_AVC_DISABLED) continue;
    break;
   case RDPGFX_CAPVERSION_101:
    if (cap->length<16 || (cap->flags & RDPGFX_CAPS_FLAG_AVC_DISABLED)) continue;
    break;
   default: continue;
  }
  if (cap->version>best.version) {
   best.version=cap->version;
   best.length=cap->version==RDPGFX_CAPVERSION_101 ? 16 : 4;
   best.flags=flags;
  }
 }
 if (!best.version) return 0;
 *selected=best;
 return 1;
}

#define RDP_GFX_MAX_INFLIGHT 3u
typedef struct {
 uint32_t frame_id;
 uint64_t sent_ms;
} rdp_gfx_pending;
typedef struct {
 uint32_t next_frame_id;
 unsigned pending;
 int suspended;
 uint64_t sent, acknowledged;
 uint64_t latest_sent_ms;
 int refresh_pending;
 rdp_gfx_pending frames[RDP_GFX_MAX_INFLIGHT];
} rdp_gfx_flow;

static inline int rdp_gfx_can_send(const rdp_gfx_flow *flow) {
 return flow && (flow->suspended || flow->pending<RDP_GFX_MAX_INFLIGHT);
}
static inline void rdp_gfx_request_refresh(rdp_gfx_flow *flow) {
 if (flow) flow->refresh_pending=1;
}
static inline int rdp_gfx_refresh_ready(const rdp_gfx_flow *flow) {
 return flow && flow->refresh_pending && rdp_gfx_can_send(flow);
}
static inline void rdp_gfx_refresh_completed(rdp_gfx_flow *flow) {
 if (flow) flow->refresh_pending=0;
}
/* The peer loop can close/reconnect a stalled session rather than leave a
 * permanently full window. Suspension intentionally disables ACK deadlines;
 * transport writes still need their independent watchdog deadline. */
static inline int rdp_gfx_ack_timed_out(const rdp_gfx_flow *flow,
 uint64_t now_ms, uint64_t timeout_ms) {
 if (!flow || flow->suspended || !flow->pending) return 0;
 uint64_t oldest=flow->frames[0].sent_ms;
 return now_ms>=oldest && now_ms-oldest>=timeout_ms;
}
/* Call only for a frame that will be submitted on the peer thread. A channel
 * write failure is fatal to that GFX session; never reuse a failed frame ID. */
static inline int rdp_gfx_frame_sent(rdp_gfx_flow *flow, uint64_t now_ms,
 uint32_t *frame_id) {
 if (!frame_id || !rdp_gfx_can_send(flow)) return 0;
 *frame_id=++flow->next_frame_id;
 flow->sent++;
 flow->latest_sent_ms=now_ms;
 if (!flow->suspended) {
  flow->frames[flow->pending++]=(rdp_gfx_pending){*frame_id,now_ms};
 }
 return 1;
}

/* Match pending IDs instead of subtracting untrusted IDs. This rejects future,
 * duplicate and stale ACKs and naturally handles uint32 wrap. ACKs retire the
 * acknowledged prefix, without allocating any client-controlled queue length.
 * During suspension retain only the latest timestamp; ACKs of that frame can
 * resume pacing. Earlier suspended frames are not counted as acknowledged. */
static inline int rdp_gfx_ack(rdp_gfx_flow *flow, uint32_t frame_id,
 uint32_t queue_depth, uint64_t now_ms, uint64_t *latency_ms) {
 if (!flow || !flow->sent) return 0;
 uint64_t sent_ms=0;
 if (flow->suspended) {
  if (frame_id!=flow->next_frame_id) return 0;
  sent_ms=flow->latest_sent_ms;
 } else {
  unsigned i;
  for (i=0;i<flow->pending;i++)
   if (flow->frames[i].frame_id==frame_id) break;
  if (i==flow->pending) return 0;
  sent_ms=flow->frames[i].sent_ms;
  unsigned retired=i+1;
  flow->pending-=retired;
  flow->acknowledged+=retired;
  memmove(flow->frames,flow->frames+retired,flow->pending*sizeof(flow->frames[0]));
 }
 flow->suspended=queue_depth==SUSPEND_FRAME_ACKNOWLEDGEMENT;
 if (flow->suspended) flow->pending=0;
 if (latency_ms) *latency_ms=now_ms>=sent_ms ? now_ms-sent_ms : 0;
 return 1;
}

typedef struct { uint64_t samples, total_latency_ms, last_latency_ms, max_latency_ms; } rdp_gfx_ack_metrics;
static inline int rdp_gfx_ack_record(rdp_gfx_flow *flow, uint32_t frame_id,
 uint32_t queue_depth, uint64_t now_ms, rdp_gfx_ack_metrics *metrics,
 uint64_t *latency_ms) {
 uint64_t measured=0;
 if (latency_ms) *latency_ms=0;
 if (!rdp_gfx_ack(flow,frame_id,queue_depth,now_ms,&measured)) return 0;
 if (metrics) {
  if (metrics->samples<UINT64_MAX) metrics->samples++;
  if (UINT64_MAX-metrics->total_latency_ms<measured) metrics->total_latency_ms=UINT64_MAX;
  else metrics->total_latency_ms+=measured;
  metrics->last_latency_ms=measured;
  if (measured>metrics->max_latency_ms) metrics->max_latency_ms=measured;
 }
 if (latency_ms) *latency_ms=measured;
 return 1;
}

static inline uint64_t rdp_gfx_ack_average_latency_ms(const rdp_gfx_ack_metrics *metrics) {
 return metrics && metrics->samples ? metrics->total_latency_ms/metrics->samples : 0;
}
static inline int rdp_gfx_ack_metrics_should_report(const rdp_gfx_ack_metrics *metrics) {
 return metrics && metrics->samples &&
        (metrics->samples==1 || metrics->samples%60==0);
}
#endif
