#!/usr/bin/env python3
"""Protocol policy tests; no service, credentials, or display access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GfxSessionTest(unittest.TestCase):
    def test_avc420_capability_policy(self):
        self.run_c(r'''
int main(void) {
 RDPGFX_CAPSET selected = {0};
 RDPGFX_CAPSET caps[] = {
  {RDPGFX_CAPVERSION_8,4,0},
  {RDPGFX_CAPVERSION_81,4,RDPGFX_CAPS_FLAG_AVC420_ENABLED},
  {RDPGFX_CAPVERSION_10,4,RDPGFX_CAPS_FLAG_AVC_DISABLED},
  {RDPGFX_CAPVERSION_102,4,0},
  {0xFFFF0000u,4,0}
 };
 CHECK(!rdp_gfx_select_avc420(0,1,caps,5,&selected));
 CHECK(!rdp_gfx_select_avc420(1,0,caps,5,&selected));
 CHECK(!rdp_gfx_select_avc420(1,1,NULL,5,&selected));
 CHECK(!rdp_gfx_select_avc420(1,1,caps,0,&selected));
 CHECK(!rdp_gfx_select_avc420(1,1,caps,5,NULL));
 CHECK(rdp_gfx_select_avc420(1,1,caps,5,&selected));
 CHECK(selected.version == RDPGFX_CAPVERSION_102);
 CHECK(selected.length == 4 && selected.flags == 0);
 CHECK(!rdp_gfx_select_avc420(1,1,caps,1,&selected));
 caps[1].flags=0;
 CHECK(!rdp_gfx_select_avc420(1,1,caps,3,&selected));
 caps[1].flags=RDPGFX_CAPS_FLAG_AVC420_ENABLED;
 CHECK(rdp_gfx_select_avc420(1,1,caps,3,&selected));
 CHECK(selected.version == RDPGFX_CAPVERSION_81);
 CHECK(selected.flags == RDPGFX_CAPS_FLAG_AVC420_ENABLED);
 caps[1].length=3;
 CHECK(!rdp_gfx_select_avc420(1,1,caps,3,&selected));
 /* Version 10.1 carries 16 bytes, including reserved fields. */
 RDPGFX_CAPSET v101={RDPGFX_CAPVERSION_101,16,0};
 CHECK(rdp_gfx_select_avc420(1,1,&v101,1,&selected));
 CHECK(selected.length==16);
 v101.length=4;
 CHECK(!rdp_gfx_select_avc420(1,1,&v101,1,&selected));
 /* An unknown newer version must not implicitly enable AVC. */
 CHECK(!rdp_gfx_select_avc420(1,1,&caps[4],1,&selected));
 return 0;
}
''')

    def test_ack_window_is_bounded_and_cumulative(self):
        self.run_c(r'''
int main(void) {
 rdp_gfx_flow flow = {0};
 uint32_t id=0; uint64_t latency=0;
 CHECK(rdp_gfx_can_send(&flow));
 CHECK(rdp_gfx_frame_sent(&flow,100,&id) && id==1);
 CHECK(rdp_gfx_frame_sent(&flow,110,&id) && id==2);
 CHECK(rdp_gfx_frame_sent(&flow,120,&id) && id==3);
 CHECK(!rdp_gfx_can_send(&flow));
 CHECK(!rdp_gfx_frame_sent(&flow,130,&id));
 CHECK(flow.sent==3 && flow.pending==3);
 CHECK(!rdp_gfx_ack(&flow,4,0,140,&latency));
 CHECK(flow.pending==3 && flow.acknowledged==0);
 CHECK(rdp_gfx_ack(&flow,2,0,150,&latency));
 CHECK(latency==40 && flow.pending==1 && flow.acknowledged==2);
 CHECK(!rdp_gfx_ack(&flow,2,0,160,&latency));
 CHECK(!rdp_gfx_ack(&flow,1,0,160,&latency));
 CHECK(rdp_gfx_frame_sent(&flow,170,&id) && id==4);
 CHECK(rdp_gfx_ack(&flow,4,0,180,&latency));
 CHECK(latency==10 && flow.pending==0 && flow.acknowledged==4);
 /* Never accept an impossible timestamp as an unsigned latency. */
 CHECK(rdp_gfx_frame_sent(&flow,200,&id));
 CHECK(rdp_gfx_ack(&flow,5,0,190,&latency) && latency==0);
 return 0;
}
''')

    def test_ack_latency_metrics_track_valid_acks(self):
        self.run_c(r'''
int main(void) {
 rdp_gfx_flow flow={0}; rdp_gfx_ack_metrics metrics={0};
 uint32_t id1=0,id2=0; uint64_t latency=0;
 CHECK(rdp_gfx_frame_sent(&flow,100,&id1));
 CHECK(rdp_gfx_frame_sent(&flow,200,&id2));
 CHECK(rdp_gfx_ack_record(&flow,id1,0,120,&metrics,&latency));
 CHECK(latency==20 && metrics.samples==1 && metrics.total_latency_ms==20);
 CHECK(metrics.last_latency_ms==20 && metrics.max_latency_ms==20);
 CHECK(rdp_gfx_ack_average_latency_ms(&metrics)==20);
 CHECK(!rdp_gfx_ack_record(&flow,id1,0,130,&metrics,&latency));
 CHECK(metrics.samples==1 && metrics.total_latency_ms==20);
 CHECK(rdp_gfx_ack_record(&flow,id2,0,230,&metrics,&latency));
 CHECK(latency==30 && metrics.samples==2 && metrics.total_latency_ms==50);
 CHECK(metrics.last_latency_ms==30 && metrics.max_latency_ms==30);
 CHECK(rdp_gfx_ack_average_latency_ms(&metrics)==25);
 return 0;
}
''')

    def test_ack_metric_reporting_is_rate_limited(self):
        self.run_c(r'''
int main(void) {
 rdp_gfx_ack_metrics metrics={0};
 CHECK(!rdp_gfx_ack_metrics_should_report(&metrics));
 metrics.samples=1; CHECK(rdp_gfx_ack_metrics_should_report(&metrics));
 metrics.samples=59; CHECK(!rdp_gfx_ack_metrics_should_report(&metrics));
 metrics.samples=60; CHECK(rdp_gfx_ack_metrics_should_report(&metrics));
 return 0;
}
''')

    def test_frame_id_wrap_and_ack_suspension(self):
        self.run_c(r'''
int main(void) {
 rdp_gfx_flow flow = {0}; uint32_t id; uint64_t latency;
 flow.next_frame_id=UINT32_MAX-1;
 CHECK(rdp_gfx_frame_sent(&flow,10,&id) && id==UINT32_MAX);
 CHECK(rdp_gfx_frame_sent(&flow,20,&id) && id==0);
 CHECK(rdp_gfx_frame_sent(&flow,30,&id) && id==1);
 CHECK(rdp_gfx_ack(&flow,0,0,40,&latency));
 CHECK(flow.pending==1 && flow.acknowledged==2 && latency==20);
 CHECK(!rdp_gfx_ack(&flow,UINT32_MAX,0,50,&latency));
 CHECK(rdp_gfx_ack(&flow,1,SUSPEND_FRAME_ACKNOWLEDGEMENT,60,&latency));
 CHECK(flow.suspended && flow.pending==0);
 for(unsigned i=0;i<1000;i++) CHECK(rdp_gfx_frame_sent(&flow,70+i,&id));
 CHECK(flow.pending==0 && rdp_gfx_can_send(&flow));
 CHECK(!rdp_gfx_ack(&flow,id+1,0,1100,&latency));
 CHECK(flow.suspended);
 /* An acknowledgement of the latest sent frame resumes normal pacing. */
 CHECK(rdp_gfx_ack(&flow,id,0,1100,&latency));
 CHECK(!flow.suspended && flow.pending==0);
 CHECK(rdp_gfx_frame_sent(&flow,1200,&id));
 CHECK(flow.pending==1);
 return 0;
}
''')

    def test_stalled_ack_deadline(self):
        self.run_c(r'''
int main(void) {
 rdp_gfx_flow flow={0}; uint32_t id; uint64_t latency;
 CHECK(!rdp_gfx_ack_timed_out(&flow,10000,5000));
 CHECK(rdp_gfx_frame_sent(&flow,100,&id));
 CHECK(rdp_gfx_frame_sent(&flow,200,&id));
 CHECK(!rdp_gfx_ack_timed_out(&flow,5099,5000));
 CHECK(rdp_gfx_ack_timed_out(&flow,5100,5000));
 CHECK(!rdp_gfx_ack_timed_out(&flow,99,5000));
 CHECK(rdp_gfx_ack(&flow,1,0,5100,&latency));
 CHECK(!rdp_gfx_ack_timed_out(&flow,5100,5000));
 CHECK(rdp_gfx_ack_timed_out(&flow,5200,5000));
 CHECK(rdp_gfx_ack(&flow,2,SUSPEND_FRAME_ACKNOWLEDGEMENT,5300,&latency));
 CHECK(!rdp_gfx_ack_timed_out(&flow,100000,5000));
 return 0;
}
''')

    def test_dropped_latest_frame_retries_when_ack_opens_window(self):
        self.run_c(r'''
int main(void) {
 rdp_gfx_flow flow={0}; uint32_t id[3]; uint64_t latency=0;
 for (unsigned i=0;i<3;i++) CHECK(rdp_gfx_frame_sent(&flow,100+i,&id[i]));
 CHECK(flow.pending==RDP_GFX_MAX_INFLIGHT);
 rdp_gfx_request_refresh(&flow);
 CHECK(flow.refresh_pending);
 CHECK(!rdp_gfx_refresh_ready(&flow));
 CHECK(rdp_gfx_ack(&flow,id[0],0,200,&latency));
 CHECK(rdp_gfx_refresh_ready(&flow));
 rdp_gfx_refresh_completed(&flow);
 CHECK(!flow.refresh_pending);
 return 0;
}
''')

    def test_frame_action_respects_surface_and_pacing_state(self):
        self.run_c(r'''
#include "gfx_runtime.h"
int main(void) {
 rdp_gfx_runtime state={0};
 rdp_gfx_runtime_init(&state,0,0);
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_RAW);
 rdp_gfx_runtime_init(&state,1,1);
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_RAW);
 state.phase=RDP_GFX_RUNTIME_WAIT_CAPS;
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_RAW);
 state.phase=RDP_GFX_RUNTIME_WAIT_RESET;
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_SETUP);
 state.phase=RDP_GFX_RUNTIME_ACTIVE;
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_SEND);
 CHECK(rdp_gfx_runtime_frame_action(&state,0)==RDP_GFX_FRAME_DROP);
 state.phase=RDP_GFX_RUNTIME_WAIT_CREATE;
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_FATAL);
 state.phase=RDP_GFX_RUNTIME_FAILED; state.surface_may_be_mapped=0;
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_RAW);
 state.surface_may_be_mapped=1;
 CHECK(rdp_gfx_runtime_frame_action(&state,1)==RDP_GFX_FRAME_FATAL);
 return 0;
}
''')

    def test_annex_b_frame_is_bounded_and_paced(self):
        self.run_c(r'''
#include "gfx_frame.h"
typedef struct {
 int calls; int fail;
 uint32_t start_id,end_id,start_time;
 uint16_t surface_id,codec_id;
 uint32_t format,left,top,right,bottom,width,height,length;
 uint32_t meta_count; uint16_t rect_left,rect_top,rect_right,rect_bottom;
 uint8_t qp,quality; uint32_t data_length; uint8_t data[8];
} frame_trace;
static UINT record_frame(RdpgfxServerContext *gfx,const RDPGFX_SURFACE_COMMAND *cmd,
                         const RDPGFX_START_FRAME_PDU *start,const RDPGFX_END_FRAME_PDU *end) {
 frame_trace *t=(frame_trace *)gfx->custom; RDPGFX_AVC420_BITMAP_STREAM *stream=(RDPGFX_AVC420_BITMAP_STREAM *)cmd->extra;
 t->calls++; t->start_id=start->frameId; t->end_id=end->frameId; t->start_time=start->timestamp;
 t->surface_id=cmd->surfaceId; t->codec_id=cmd->codecId; t->format=cmd->format;
 t->left=cmd->left; t->top=cmd->top; t->right=cmd->right; t->bottom=cmd->bottom;
 t->width=cmd->width; t->height=cmd->height; t->length=cmd->length;
 t->meta_count=stream->meta.numRegionRects;
 t->rect_left=stream->meta.regionRects[0].left; t->rect_top=stream->meta.regionRects[0].top;
 t->rect_right=stream->meta.regionRects[0].right; t->rect_bottom=stream->meta.regionRects[0].bottom;
 t->qp=stream->meta.quantQualityVals[0].qp; t->quality=stream->meta.quantQualityVals[0].qualityVal;
 t->data_length=stream->length; memcpy(t->data,stream->data,stream->length>sizeof(t->data)?sizeof(t->data):stream->length);
 return t->fail ? 1 : CHANNEL_RC_OK;
}
int main(void) {
 const uint8_t annexb[]={0,0,0,1,0x65,0x88,0x99};
 rdp_gfx_flow flow={0}; RdpgfxServerContext gfx={0}; frame_trace t={0};
 gfx.custom=&t; gfx.SurfaceFrameCommand=record_frame;
 CHECK(rdp_gfx_send_avc420_frame(&gfx,&flow,5,640,480,annexb,sizeof(annexb),1234));
 CHECK(t.calls==1 && flow.sent==1 && flow.pending==1);
 CHECK(t.start_id==1 && t.end_id==1 && t.start_time==1234);
 CHECK(t.surface_id==5 && t.codec_id==RDPGFX_CODECID_AVC420 && t.format==PIXEL_FORMAT_BGRX32);
 CHECK(t.left==0 && t.top==0 && t.right==640 && t.bottom==480);
 CHECK(t.width==640 && t.height==480 && t.length==sizeof(annexb));
 CHECK(t.meta_count==1 && t.rect_left==0 && t.rect_top==0 && t.rect_right==640 && t.rect_bottom==480);
 CHECK(t.qp==0 && t.quality==100 && t.data_length==sizeof(annexb));
 CHECK(memcmp(t.data,annexb,sizeof(annexb))==0);
 CHECK(!rdp_gfx_send_avc420_frame(&gfx,&flow,5,640,480,annexb,0,1235));
 CHECK(!rdp_gfx_send_avc420_frame(&gfx,&flow,5,640,480,annexb,RDP_GFX_MAX_ACCESS_UNIT_BYTES+1u,1235));
 CHECK(t.calls==1 && flow.sent==1);
 t.fail=1;
 CHECK(!rdp_gfx_send_avc420_frame(&gfx,&flow,5,640,480,annexb,sizeof(annexb),1236));
 CHECK(flow.sent==2 && flow.pending==2);
 return 0;
}
''')

    def test_first_annex_b_frame_precedes_surface_mapping(self):
        self.run_c(r'''
#include "gfx_frame.h"
typedef struct { int count; int event[4]; uint32_t bytes; } order_trace;
static void mark(RdpgfxServerContext *gfx,int event) {
 order_trace *t=(order_trace *)gfx->custom; t->event[t->count++]=event;
}
static UINT reset_cb(RdpgfxServerContext *gfx,const RDPGFX_RESET_GRAPHICS_PDU *pdu) {
 (void)pdu; mark(gfx,1); return CHANNEL_RC_OK;
}
static UINT create_cb(RdpgfxServerContext *gfx,const RDPGFX_CREATE_SURFACE_PDU *pdu) {
 (void)pdu; mark(gfx,2); return CHANNEL_RC_OK;
}
static UINT map_cb(RdpgfxServerContext *gfx,const RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU *pdu) {
 (void)pdu; mark(gfx,3); return CHANNEL_RC_OK;
}
static UINT frame_cb(RdpgfxServerContext *gfx,const RDPGFX_SURFACE_COMMAND *cmd,
                     const RDPGFX_START_FRAME_PDU *start,const RDPGFX_END_FRAME_PDU *end) {
 order_trace *t=(order_trace *)gfx->custom; RDPGFX_AVC420_BITMAP_STREAM *stream=(RDPGFX_AVC420_BITMAP_STREAM *)cmd->extra;
 (void)start; (void)end; t->bytes=stream->length; mark(gfx,4); return CHANNEL_RC_OK;
}
int main(void) {
 rdp_gfx_runtime runtime={0}; rdp_gfx_flow flow={0}; RdpgfxServerContext gfx={0}; order_trace t={0};
 const uint8_t data[]={0,0,0,1,0x65}; gfx.custom=&t;
 gfx.ResetGraphics=reset_cb; gfx.CreateSurface=create_cb; gfx.MapSurfaceToOutput=map_cb; gfx.SurfaceFrameCommand=frame_cb;
 rdp_gfx_runtime_init(&runtime,1,1); runtime.phase=RDP_GFX_RUNTIME_WAIT_RESET;
 rdp_gfx_request_refresh(&flow);
 CHECK(!rdp_gfx_send_first_avc420_frame(&runtime,&gfx,&flow,0,640,480,NULL,0,100));
 CHECK(!rdp_gfx_send_first_avc420_frame(&runtime,&gfx,&flow,0,640,480,data,RDP_GFX_MAX_ACCESS_UNIT_BYTES+1u,100));
 CHECK(t.count==0 && runtime.phase==RDP_GFX_RUNTIME_WAIT_RESET && flow.refresh_pending);
 CHECK(rdp_gfx_send_first_avc420_frame(&runtime,&gfx,&flow,0,640,480,data,sizeof(data),101));
 CHECK(t.count==4 && t.event[0]==1 && t.event[1]==2 && t.event[2]==3 && t.event[3]==4);
 CHECK(t.bytes==sizeof(data) && runtime.phase==RDP_GFX_RUNTIME_ACTIVE);
 CHECK(flow.sent==1 && flow.pending==1 && !flow.refresh_pending);
 return 0;
}
''')

    def test_surface_pdus_use_ordered_desktop_geometry(self):
        self.run_c(r'''
#include "gfx_surface.h"
typedef struct {
 int order[3]; int count; int fail_on;
 uint32_t reset_width,reset_height; uint32_t monitor_count;
 int32_t left,top,right,bottom; uint32_t monitor_flags;
 uint16_t create_width,create_height,create_surface; uint8_t pixel_format;
 uint16_t map_surface,map_reserved; uint32_t map_x,map_y;
} trace;
static UINT record_reset(RdpgfxServerContext *gfx,const RDPGFX_RESET_GRAPHICS_PDU *pdu) {
 trace *t=(trace *)gfx->custom; t->order[t->count++]=1;
 t->reset_width=pdu->width; t->reset_height=pdu->height; t->monitor_count=pdu->monitorCount;
 t->left=pdu->monitorDefArray[0].left; t->top=pdu->monitorDefArray[0].top;
 t->right=pdu->monitorDefArray[0].right; t->bottom=pdu->monitorDefArray[0].bottom;
 t->monitor_flags=pdu->monitorDefArray[0].flags;
 return t->fail_on==1 ? 1 : CHANNEL_RC_OK;
}
static UINT record_create(RdpgfxServerContext *gfx,const RDPGFX_CREATE_SURFACE_PDU *pdu) {
 trace *t=(trace *)gfx->custom; t->order[t->count++]=2;
 t->create_width=pdu->width; t->create_height=pdu->height;
 t->create_surface=pdu->surfaceId; t->pixel_format=pdu->pixelFormat;
 return t->fail_on==2 ? 1 : CHANNEL_RC_OK;
}
static UINT record_map(RdpgfxServerContext *gfx,const RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU *pdu) {
 trace *t=(trace *)gfx->custom; t->order[t->count++]=3;
 t->map_surface=pdu->surfaceId; t->map_reserved=pdu->reserved;
 t->map_x=pdu->outputOriginX; t->map_y=pdu->outputOriginY;
 return t->fail_on==3 ? 1 : CHANNEL_RC_OK;
}
static void prepare(rdp_gfx_runtime *state,RdpgfxServerContext *gfx,trace *t) {
 rdp_gfx_runtime_init(state,1,1);
 (void)rdp_gfx_runtime_channel_opened(state,1);
 (void)rdp_gfx_runtime_caps_confirmed(state,1);
 gfx->custom=t; gfx->ResetGraphics=record_reset;
 gfx->CreateSurface=record_create; gfx->MapSurfaceToOutput=record_map;
}
int main(void) {
 rdp_gfx_runtime state={0}; RdpgfxServerContext gfx={0}; trace t={0};
 prepare(&state,&gfx,&t);
 CHECK(rdp_gfx_surface_setup(&state,&gfx,1920,1080,7));
 CHECK(t.count==3 && t.order[0]==1 && t.order[1]==2 && t.order[2]==3);
 CHECK(t.reset_width==1920 && t.reset_height==1080 && t.monitor_count==1);
 CHECK(t.left==0 && t.top==0 && t.right==1920 && t.bottom==1080 && t.monitor_flags==1);
 CHECK(t.create_width==1920 && t.create_height==1080 && t.create_surface==7);
 CHECK(t.pixel_format==GFX_PIXEL_FORMAT_XRGB_8888);
 CHECK(t.map_surface==7 && t.map_reserved==0 && t.map_x==0 && t.map_y==0);
 CHECK(state.phase==RDP_GFX_RUNTIME_ACTIVE && !rdp_gfx_runtime_can_fallback_raw(&state));
 t=(trace){.fail_on=2}; prepare(&state,&gfx,&t);
 CHECK(!rdp_gfx_surface_setup(&state,&gfx,800,600,1));
 CHECK(t.count==2 && state.phase==RDP_GFX_RUNTIME_FAILED && rdp_gfx_runtime_can_fallback_raw(&state));
 t=(trace){.fail_on=3}; prepare(&state,&gfx,&t);
 CHECK(!rdp_gfx_surface_setup(&state,&gfx,800,600,1));
 CHECK(t.count==3 && state.phase==RDP_GFX_RUNTIME_FAILED && !rdp_gfx_runtime_can_fallback_raw(&state));
 t=(trace){0}; prepare(&state,&gfx,&t);
 CHECK(!rdp_gfx_surface_setup(&state,&gfx,65536,600,1));
 CHECK(t.count==0 && state.phase==RDP_GFX_RUNTIME_FAILED && rdp_gfx_runtime_can_fallback_raw(&state));
 return 0;
}
''')

    def test_surface_dimensions_fit_wire_fields(self):
        self.run_c(r'''
#include <stdint.h>
#include "gfx_runtime.h"
int main(void) {
 CHECK(rdp_gfx_surface_dimensions_valid(1,1));
 CHECK(rdp_gfx_surface_dimensions_valid(65535,32768));
 CHECK(!rdp_gfx_surface_dimensions_valid(0,1));
 CHECK(!rdp_gfx_surface_dimensions_valid(1,0));
 CHECK(!rdp_gfx_surface_dimensions_valid(65536,1));
 CHECK(!rdp_gfx_surface_dimensions_valid(1,65536));
 return 0;
}
''')

    def test_surface_commands_are_ordered_and_fail_closed(self):
        self.run_c(r'''
#include "gfx_runtime.h"
typedef struct { int commands[3]; int count; int fail_on; } trace;
static int send_command(void *opaque, int command) {
 trace *t=(trace *)opaque;
 t->commands[t->count++]=command;
 return command!=t->fail_on;
}
static int enter_wait_reset(rdp_gfx_runtime *state) {
 rdp_gfx_runtime_init(state,1,1);
 return rdp_gfx_runtime_channel_opened(state,1) &&
        rdp_gfx_runtime_caps_confirmed(state,1);
}
int main(void) {
 rdp_gfx_runtime state={0}; trace t={{0},0,-1};
 CHECK(enter_wait_reset(&state));
 CHECK(rdp_gfx_runtime_setup_surface(&state,send_command,&t));
 CHECK(t.count==3 && t.commands[0]==1 && t.commands[1]==2 && t.commands[2]==3);
 CHECK(state.phase==RDP_GFX_RUNTIME_ACTIVE && !rdp_gfx_runtime_can_fallback_raw(&state));
 t=(trace){{0},0,2};
 CHECK(enter_wait_reset(&state));
 CHECK(!rdp_gfx_runtime_setup_surface(&state,send_command,&t));
 CHECK(t.count==2 && t.commands[0]==1 && t.commands[1]==2);
 CHECK(state.phase==RDP_GFX_RUNTIME_FAILED && rdp_gfx_runtime_can_fallback_raw(&state));
 t=(trace){{0},0,3};
 CHECK(enter_wait_reset(&state));
 CHECK(!rdp_gfx_runtime_setup_surface(&state,send_command,&t));
 CHECK(t.count==3 && t.commands[2]==3);
 CHECK(state.phase==RDP_GFX_RUNTIME_FAILED && !rdp_gfx_runtime_can_fallback_raw(&state));
 return 0;
}
''')

    def test_runtime_lifecycle_fails_closed(self):
        self.run_c(r'''
#include "gfx_runtime.h"
int main(void) {
 rdp_gfx_runtime state={0};
 rdp_gfx_runtime_init(&state,0,1);
 CHECK(state.phase==RDP_GFX_RUNTIME_RAW);
 CHECK(rdp_gfx_runtime_can_fallback_raw(&state));
 CHECK(!rdp_gfx_runtime_should_open(&state,1,1));
 rdp_gfx_runtime_init(&state,1,0);
 CHECK(state.phase==RDP_GFX_RUNTIME_RAW);
 rdp_gfx_runtime_init(&state,1,1);
 CHECK(state.phase==RDP_GFX_RUNTIME_WAIT_DRDYNVC);
 CHECK(rdp_gfx_runtime_can_fallback_raw(&state));
 CHECK(!rdp_gfx_runtime_should_open(&state,0,0));
 CHECK(!rdp_gfx_runtime_should_open(&state,0,1));
 CHECK(!rdp_gfx_runtime_should_open(&state,1,0));
 CHECK(rdp_gfx_runtime_should_open(&state,1,1));
 CHECK(rdp_gfx_runtime_channel_opened(&state,1));
 CHECK(state.phase==RDP_GFX_RUNTIME_WAIT_CAPS);
 CHECK(!rdp_gfx_runtime_can_send(&state));
 CHECK(rdp_gfx_runtime_caps_confirmed(&state,1));
 CHECK(rdp_gfx_runtime_surface_reset(&state,1));
 CHECK(rdp_gfx_runtime_surface_created(&state,1));
 CHECK(rdp_gfx_runtime_surface_map_result(&state,1));
 CHECK(state.phase==RDP_GFX_RUNTIME_ACTIVE);
 CHECK(!rdp_gfx_runtime_can_fallback_raw(&state));
 CHECK(rdp_gfx_runtime_can_send(&state));
 CHECK(!rdp_gfx_runtime_surface_created(&state,1));
 CHECK(state.phase==RDP_GFX_RUNTIME_FAILED);
 CHECK(!rdp_gfx_runtime_can_fallback_raw(&state));
 CHECK(!rdp_gfx_runtime_can_send(&state));
 rdp_gfx_runtime_init(&state,1,1);
 CHECK(rdp_gfx_runtime_channel_opened(&state,1));
 CHECK(!rdp_gfx_runtime_caps_confirmed(&state,0));
 CHECK(state.phase==RDP_GFX_RUNTIME_FAILED);
 CHECK(rdp_gfx_runtime_can_fallback_raw(&state));
 /* A failed map send may still have partially reached the client. */
 rdp_gfx_runtime_init(&state,1,1);
 CHECK(rdp_gfx_runtime_channel_opened(&state,1));
 CHECK(rdp_gfx_runtime_caps_confirmed(&state,1));
 CHECK(rdp_gfx_runtime_surface_reset(&state,1));
 CHECK(rdp_gfx_runtime_surface_created(&state,1));
 CHECK(!rdp_gfx_runtime_surface_map_result(&state,0));
 CHECK(state.phase==RDP_GFX_RUNTIME_FAILED);
 CHECK(state.surface_may_be_mapped);
 CHECK(!rdp_gfx_runtime_can_fallback_raw(&state));
 return 0;
}
''')

    def run_c(self, body):
        header = ROOT / "internal/worker/gfx_session.h"
        self.assertTrue(header.is_file(), "GFX AVC420 negotiation/flow policy is not implemented")
        source = '#include "gfx_session.h"\n#include <stdio.h>\n#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\\n",__LINE__,#x); return 1; } } while(0)\n' + body
        with tempfile.TemporaryDirectory(prefix="rdp-gfx-policy-") as directory:
            binary = Path(directory) / "test"
            command = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "internal/worker"), "-isystem", str(ROOT / ".deps/install/include/freerdp3"), "-isystem", str(ROOT / ".deps/install/include/winpr3")]
            if os.environ.get("RDP_TEST_ASAN") == "1":
                command += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            result = subprocess.run(command + ["-x", "c", "-", "-o", str(binary)], input=source, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
