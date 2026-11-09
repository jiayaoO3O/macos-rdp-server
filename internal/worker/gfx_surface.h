/* Native RDPGFX surface PDU construction and lifecycle entry point. */
#ifndef RDP_GFX_SURFACE_H
#define RDP_GFX_SURFACE_H

#include <stdint.h>
#include <freerdp/channels/channels.h>
#include <freerdp/server/rdpgfx.h>

#include "gfx_runtime.h"

typedef struct {
 RdpgfxServerContext *gfx;
 uint32_t width;
 uint32_t height;
 uint16_t surface_id;
 MONITOR_DEF monitor;
} rdp_gfx_surface_request;

static inline int rdp_gfx_surface_send_command(void *opaque, int command) {
 rdp_gfx_surface_request *request=(rdp_gfx_surface_request *)opaque;
 if (!request || !request->gfx ||
     !rdp_gfx_surface_dimensions_valid(request->width,request->height)) return 0;
 switch (command) {
  case RDP_GFX_SURFACE_COMMAND_RESET: {
   RDPGFX_RESET_GRAPHICS_PDU pdu={0};
   if (!request->gfx->ResetGraphics) return 0;
   request->monitor.left=0;
   request->monitor.top=0;
   request->monitor.right=(INT32)request->width;
   request->monitor.bottom=(INT32)request->height;
   request->monitor.flags=MONITOR_PRIMARY;
   pdu.width=request->width;
   pdu.height=request->height;
   pdu.monitorCount=1;
   pdu.monitorDefArray=&request->monitor;
   return request->gfx->ResetGraphics(request->gfx,&pdu)==CHANNEL_RC_OK;
  }
  case RDP_GFX_SURFACE_COMMAND_CREATE: {
   RDPGFX_CREATE_SURFACE_PDU pdu={0};
   if (!request->gfx->CreateSurface) return 0;
   pdu.surfaceId=request->surface_id;
   pdu.width=(UINT16)request->width;
   pdu.height=(UINT16)request->height;
   pdu.pixelFormat=GFX_PIXEL_FORMAT_XRGB_8888;
   return request->gfx->CreateSurface(request->gfx,&pdu)==CHANNEL_RC_OK;
  }
  case RDP_GFX_SURFACE_COMMAND_MAP: {
   RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU pdu={0};
   if (!request->gfx->MapSurfaceToOutput) return 0;
   pdu.surfaceId=request->surface_id;
   pdu.reserved=0;
   pdu.outputOriginX=0;
   pdu.outputOriginY=0;
   return request->gfx->MapSurfaceToOutput(request->gfx,&pdu)==CHANNEL_RC_OK;
  }
  default:
   return 0;
 }
}

static inline int rdp_gfx_surface_setup(rdp_gfx_runtime *runtime,
                                         RdpgfxServerContext *gfx,
                                         uint32_t width, uint32_t height,
                                         uint16_t surface_id) {
 rdp_gfx_surface_request request={0};
 request.gfx=gfx;
 request.width=width;
 request.height=height;
 request.surface_id=surface_id;
 return rdp_gfx_runtime_setup_surface(runtime,rdp_gfx_surface_send_command,&request);
}

#endif
