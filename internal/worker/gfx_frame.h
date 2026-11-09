/* Bounded Annex-B AVC420 surface-frame submission. */
#ifndef RDP_GFX_FRAME_H
#define RDP_GFX_FRAME_H

#include <stdint.h>
#include <freerdp/channels/channels.h>
#include <freerdp/codec/color.h>
#include <freerdp/server/rdpgfx.h>

#include "gfx_runtime.h"
#include "gfx_session.h"
#include "gfx_surface.h"

#define RDP_GFX_MAX_ACCESS_UNIT_BYTES (4u * 1024u * 1024u)

static inline int rdp_gfx_send_avc420_frame(RdpgfxServerContext *gfx,
                                             rdp_gfx_flow *flow,
                                             uint16_t surface_id,
                                             uint32_t width, uint32_t height,
                                             const uint8_t *annexb,
                                             size_t annexb_length,
                                             uint32_t timestamp_ms) {
 if (!gfx || !gfx->SurfaceFrameCommand || !flow || !annexb || annexb_length==0 ||
     annexb_length>RDP_GFX_MAX_ACCESS_UNIT_BYTES ||
     !rdp_gfx_surface_dimensions_valid(width,height) || !rdp_gfx_can_send(flow)) return 0;
 RDPGFX_AVC420_BITMAP_STREAM stream={0};
 RECTANGLE_16 region={0};
 RDPGFX_H264_QUANT_QUALITY quality={0};
 RDPGFX_SURFACE_COMMAND command={0};
 RDPGFX_START_FRAME_PDU start={0};
 RDPGFX_END_FRAME_PDU end={0};
 uint32_t frame_id=0;
 region.right=(UINT16)width;
 region.bottom=(UINT16)height;
 quality.qp=0;
 quality.qualityVal=100;
 stream.meta.numRegionRects=1;
 stream.meta.regionRects=&region;
 stream.meta.quantQualityVals=&quality;
 stream.length=(UINT32)annexb_length;
 stream.data=(BYTE *)annexb;
 command.surfaceId=surface_id;
 command.codecId=RDPGFX_CODECID_AVC420;
 command.format=PIXEL_FORMAT_BGRX32;
 command.left=0;
 command.top=0;
 command.right=width;
 command.bottom=height;
 command.width=width;
 command.height=height;
 command.length=(UINT32)annexb_length;
 command.data=(BYTE *)annexb;
 command.extra=&stream;
 if (!rdp_gfx_frame_sent(flow,timestamp_ms,&frame_id)) return 0;
 start.frameId=frame_id;
 start.timestamp=timestamp_ms;
 end.frameId=frame_id;
 UINT rc=gfx->SurfaceFrameCommand(gfx,&command,&start,&end);
 if (rc!=CHANNEL_RC_OK) return 0;
 rdp_gfx_refresh_completed(flow);
 return 1;
}

static inline int rdp_gfx_send_first_avc420_frame(rdp_gfx_runtime *runtime,
                                                   RdpgfxServerContext *gfx,
                                                   rdp_gfx_flow *flow,
                                                   uint16_t surface_id,
                                                   uint32_t width, uint32_t height,
                                                   const uint8_t *annexb,
                                                   size_t annexb_length,
                                                   uint32_t timestamp_ms) {
 if (!runtime || runtime->phase!=RDP_GFX_RUNTIME_WAIT_RESET || !annexb ||
     annexb_length==0 || annexb_length>RDP_GFX_MAX_ACCESS_UNIT_BYTES ||
     !rdp_gfx_surface_dimensions_valid(width,height)) return 0;
 if (!rdp_gfx_surface_setup(runtime,gfx,width,height,surface_id)) return 0;
 return rdp_gfx_send_avc420_frame(gfx,flow,surface_id,width,height,annexb,
                                  annexb_length,timestamp_ms);
}

#endif
