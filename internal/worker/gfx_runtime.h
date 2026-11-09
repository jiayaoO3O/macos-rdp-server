/* Fail-closed, peer-thread-only GFX channel/surface lifecycle gates. */
#ifndef RDP_GFX_RUNTIME_H
#define RDP_GFX_RUNTIME_H

#include <stdint.h>

typedef enum {
 RDP_GFX_RUNTIME_RAW=0,
 RDP_GFX_RUNTIME_WAIT_DRDYNVC,
 RDP_GFX_RUNTIME_WAIT_CAPS,
 RDP_GFX_RUNTIME_WAIT_RESET,
 RDP_GFX_RUNTIME_WAIT_CREATE,
 RDP_GFX_RUNTIME_WAIT_MAP,
 RDP_GFX_RUNTIME_ACTIVE,
 RDP_GFX_RUNTIME_FAILED
} rdp_gfx_runtime_phase;

typedef struct { rdp_gfx_runtime_phase phase; int surface_may_be_mapped; } rdp_gfx_runtime;

static inline void rdp_gfx_runtime_init(rdp_gfx_runtime *state, int opted_in, int encoder_ready) {
 if (!state) return;
 state->phase=(opted_in && encoder_ready) ? RDP_GFX_RUNTIME_WAIT_DRDYNVC : RDP_GFX_RUNTIME_RAW;
 state->surface_may_be_mapped=0;
}

static inline int rdp_gfx_runtime_should_open(const rdp_gfx_runtime *state, int drdynvc_joined, int drdynvc_ready) {
 return state && drdynvc_joined && drdynvc_ready && state->phase==RDP_GFX_RUNTIME_WAIT_DRDYNVC;
}

static inline int rdp_gfx_runtime_step(rdp_gfx_runtime *state, rdp_gfx_runtime_phase expected,
                                        rdp_gfx_runtime_phase next, int succeeded) {
 if (!state || state->phase==RDP_GFX_RUNTIME_RAW || state->phase==RDP_GFX_RUNTIME_FAILED) return 0;
 if (state->phase!=expected || !succeeded) {
  state->phase=RDP_GFX_RUNTIME_FAILED;
  return 0;
 }
 state->phase=next;
 return 1;
}

static inline int rdp_gfx_runtime_channel_opened(rdp_gfx_runtime *state, int succeeded) {
 return rdp_gfx_runtime_step(state,RDP_GFX_RUNTIME_WAIT_DRDYNVC,RDP_GFX_RUNTIME_WAIT_CAPS,succeeded);
}
static inline int rdp_gfx_runtime_caps_confirmed(rdp_gfx_runtime *state, int succeeded) {
 return rdp_gfx_runtime_step(state,RDP_GFX_RUNTIME_WAIT_CAPS,RDP_GFX_RUNTIME_WAIT_RESET,succeeded);
}
static inline int rdp_gfx_runtime_surface_reset(rdp_gfx_runtime *state, int succeeded) {
 return rdp_gfx_runtime_step(state,RDP_GFX_RUNTIME_WAIT_RESET,RDP_GFX_RUNTIME_WAIT_CREATE,succeeded);
}
static inline int rdp_gfx_runtime_surface_created(rdp_gfx_runtime *state, int succeeded) {
 return rdp_gfx_runtime_step(state,RDP_GFX_RUNTIME_WAIT_CREATE,RDP_GFX_RUNTIME_WAIT_MAP,succeeded);
}
static inline int rdp_gfx_runtime_surface_map_result(rdp_gfx_runtime *state, int succeeded) {
 if (!state) return 0;
 /* A failed send can be partial; after attempting MapSurfaceToOutput raw fallback is unsafe. */
 state->surface_may_be_mapped=1;
 return rdp_gfx_runtime_step(state,RDP_GFX_RUNTIME_WAIT_MAP,RDP_GFX_RUNTIME_ACTIVE,succeeded);
}
static inline int rdp_gfx_surface_dimensions_valid(uint32_t width, uint32_t height) {
 return width>0 && height>0 && width<=UINT16_MAX && height<=UINT16_MAX;
}

typedef enum {
 RDP_GFX_SURFACE_COMMAND_RESET=1,
 RDP_GFX_SURFACE_COMMAND_CREATE=2,
 RDP_GFX_SURFACE_COMMAND_MAP=3
} rdp_gfx_surface_command;
typedef int (*rdp_gfx_surface_command_sender)(void *opaque, int command);
static inline int rdp_gfx_runtime_setup_surface(rdp_gfx_runtime *state,
                                                rdp_gfx_surface_command_sender send,
                                                void *opaque) {
 if (!state) return 0;
 if (state->phase!=RDP_GFX_RUNTIME_WAIT_RESET || !send) {
  if (state->phase!=RDP_GFX_RUNTIME_RAW && state->phase!=RDP_GFX_RUNTIME_FAILED)
   state->phase=RDP_GFX_RUNTIME_FAILED;
  return 0;
 }
 if (!rdp_gfx_runtime_surface_reset(state,send(opaque,RDP_GFX_SURFACE_COMMAND_RESET))) return 0;
 if (!rdp_gfx_runtime_surface_created(state,send(opaque,RDP_GFX_SURFACE_COMMAND_CREATE))) return 0;
 return rdp_gfx_runtime_surface_map_result(state,send(opaque,RDP_GFX_SURFACE_COMMAND_MAP));
}
static inline int rdp_gfx_runtime_can_fallback_raw(const rdp_gfx_runtime *state) {
 return state && !state->surface_may_be_mapped;
}
static inline int rdp_gfx_runtime_can_send(const rdp_gfx_runtime *state) {
 return state && state->phase==RDP_GFX_RUNTIME_ACTIVE;
}

typedef enum {
 RDP_GFX_FRAME_RAW=0,
 RDP_GFX_FRAME_SETUP,
 RDP_GFX_FRAME_SEND,
 RDP_GFX_FRAME_DROP,
 RDP_GFX_FRAME_FATAL
} rdp_gfx_frame_action;
static inline rdp_gfx_frame_action rdp_gfx_runtime_frame_action(const rdp_gfx_runtime *state,
                                                                  int flow_can_send) {
 if (!state) return RDP_GFX_FRAME_RAW;
 switch (state->phase) {
  case RDP_GFX_RUNTIME_WAIT_RESET: return RDP_GFX_FRAME_SETUP;
  case RDP_GFX_RUNTIME_ACTIVE: return flow_can_send ? RDP_GFX_FRAME_SEND : RDP_GFX_FRAME_DROP;
  case RDP_GFX_RUNTIME_WAIT_CREATE:
  case RDP_GFX_RUNTIME_WAIT_MAP: return RDP_GFX_FRAME_FATAL;
  case RDP_GFX_RUNTIME_FAILED:
   return rdp_gfx_runtime_can_fallback_raw(state) ? RDP_GFX_FRAME_RAW : RDP_GFX_FRAME_FATAL;
  default: return RDP_GFX_FRAME_RAW;
 }
}

#endif
