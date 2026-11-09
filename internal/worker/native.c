/* FreeRDP adapter: all peers, frames and settings are owned by C. No retained
 * Go pointers. Each peer event loop stays on its own pthread. */
#include "native.h"
#include "frame_generation.h"
#include "clipboard_handshake.h"
#include "clipboard_files.h"
#include "dirty_tiles.h"
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
#include "avc_encoder.h"
#include "gfx_frame.h"
#include "gfx_surface.h"
#include <freerdp/server/rdpgfx.h>
#include <winpr/error.h>
#endif
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/event.h>
#include <freerdp/addin.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <freerdp/input.h>
#include <freerdp/codec/color.h>
#include <freerdp/codec/planar.h>
#include <freerdp/codec/nsc.h>
#include <freerdp/server/cliprdr.h>
#include <freerdp/server/disp.h>
#include <freerdp/streamdump.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/wtsvc.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/ntlm.h>
#include <winpr/sam.h>
#include <ctype.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/crt.h>
#include <winpr/string.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern unsigned long long goAuthorize(char *user, char *domain);
extern void goRelease(unsigned long long token);
extern void goLeaseHeartbeat(unsigned long long token);

#define WIDTH 800
#define HEIGHT 600
#define MAX_PEERS 4
#define MAX_FRAME_BYTES (64u * 1024u * 1024u)
#define FRAME_IPC_HEADER 12u
#define FRAME_CHUNK_HEADER 20u
#define MAX_AGENT_IPC_PAYLOAD (64u*1024u)
/* Worker -> Agent IPC message types that this file sends by name (the wire
 * format is `RDPA` + u16 version 1 + u16 type + u32 BE payload length; the
 * clipboard file types 13..16 are defined in clipboard_files.h). */
#define AGENT_IPC_TYPE_DISPLAY_RESTORE 17u    /* empty payload: restore display mode */
#define BITMAP_BATCH_RECT_LIMIT 32u
/* Clipboard file streaming (Issue 3): abort a remote->local offer when the
 * client stops answering CB_FILECONTENTS_REQUEST for this long. The flag is
 * cooperative: the peer loop only sets it, the cliprdr channel thread aborts
 * its own state on the next callback (no cross-thread blocking, no locks). */
#define CLIPBOARD_FILE_STALL_MS 30000u
/* Client-driven resolution adaptation (2026-11-07): the negotiated desktop must
 * fit the frame buffers and the agent IPC frame maximum. Requests outside these
 * bounds are clamped proportionally instead of being rejected, so a client that
 * asks for an unsupported resolution still gets a working desktop. */
#define MAX_DESKTOP_DIM 16384u
#define DESKTOP_PIXEL_BUDGET (MAX_FRAME_BYTES/4u) /* 16,777,216 pixels */

/* Local (macOS) file advertised to the RDP client (direction 2, Agent ->
 * worker). name/path are NUL-terminated malloc-owned UTF-8 validated by
 * clipboard_files.h; path is absolute. */
typedef struct {
 char *name;
 UINT32 name_length;
 char *path;
 UINT32 path_length;
 UINT64 size;
} rdp_clipboard_local_file;

typedef struct {
 const char *cert, *key, *sam, *agent_socket;
 BOOL test_pattern;
 BOOL clipboard_enabled;
 pthread_mutex_t mutex;
 pthread_mutex_t frame_mutex;
 pthread_mutex_t agent_mutex;
 pthread_mutex_t clipboard_mutex;
 int agent_client_fd;
 /* Local clipboard text (IPC type 8) and local clipboard file list (IPC types
  * 13/15/16, direction 2). All fields up to local_offer_files are guarded by
  * clipboard_mutex; the cliprdr callbacks copy what they need and never hold
  * the lock across file I/O. */
 BYTE *clipboard_utf8;
 UINT32 clipboard_utf8_length;
 rdp_clipboard_local_file *local_files;
 UINT32 local_file_count;
 UINT64 local_file_total_bytes;
 BYTE *local_descriptors; /* cached serialized FileGroupDescriptorW list */
 UINT32 local_descriptors_length;
 /* In-progress Agent direction-2 offer assembly (begin -> entries -> end). */
 BOOL local_offer_active;
 UINT32 local_offer_expected;
 UINT32 local_offer_received;
 UINT64 local_offer_bytes;
 rdp_clipboard_status local_offer_error;
 rdp_clipboard_local_file *local_offer_files;
 BYTE *frame_pixels;
 UINT32 frame_width, frame_height;
 /* Last desktop size requested from the Agent via IPC message type 9. Kept so
  * a restarted Agent IPC connection can re-sync to the negotiated RDP size
  * without waiting for a new RDP connection. */
 UINT32 requested_width, requested_height;
 UINT64 frame_generation, frame_id;
 struct peer_job *jobs[MAX_PEERS];
} server_options;
typedef struct peer_job {
 freerdp_peer *peer;
 psPeerSendServerRedirection original_redirection;
 server_options *options;
 unsigned slot;
 int cancel_fd;
 HANDLE frame_event;
 BOOL cancelled;
 UINT64 deadline;
} peer_job;
typedef struct {
 rdpContext context;
 BOOL leased, ready;
 /* Single-session lease token from goAuthorize. Only the token owner may release
  * the gate, so a peer whose lease was taken over after going stale cannot drop
  * the lease of the connection that replaced it. */
 UINT64 lease_token, next_heartbeat;
 /* Set from the client's TS_SUPPRESS_OUTPUT_PDU (minimised client). While set,
  * the peer sends no bitmap updates; on resume it sends one full frame. */
 BOOL output_suppressed;
 /* Early input arriving before activation is legal and is ignored; log the first
  * one per peer so a real fast-reconnect race is visible in the field. */
 BOOL early_input_logged;
 unsigned inputs;
 UINT32 width, height;
 HANDLE vcm;
 CliprdrServerContext *cliprdr;
 /* Clipboard file state (Issue 3, contract section 4). cliprdr_advertised_kind
  * is the last CB_FORMAT_LIST advertised to this client and is guarded by
  * options->clipboard_mutex (the Agent IPC thread broadcasts local clipboard
  * changes). The remote->local streaming state (clip_file_*) is only mutated by
  * the cliprdr channel thread; the peer thread merely sets
  * clip_file_cancel_requested after a stall and aborts the offer at teardown,
  * after Stop() has joined the cliprdr thread. */
 UINT32 cliprdr_advertised_kind;
 /* Semantic kind (RDP_CLIPBOARD_KIND_*: 0 none / 1 text / 2 files) of the
  * CB_FORMAT_DATA_REQUEST we sent, not its format id: the id is whatever the
  * client advertised (dynamic for real mstsc file formats), so the response
  * must be dispatched by meaning. cliprdr thread only. */
 UINT32 cliprdr_pending_kind;
 /* TRUE once the server-side clipboard initialization sequence (CB_CLIP_CAPS +
  * CB_MONITOR_READY) has been queued on the channel by the peer thread. Local
  * clipboard changes are only advertised after that point: a CB_FORMAT_LIST
  * that overtakes the initialization sequence is a protocol violation and the
  * FreeRDP client kills its cliprdr channel on it (test_26 flake). */
 volatile BOOL cliprdr_initialized;
 volatile BOOL clip_file_stream_active; /* cliprdr thread writes, peer thread reads */
 volatile BOOL clip_file_cancel_requested;
 UINT32 clip_file_stream_id;
 UINT32 clip_file_stream_count;
 UINT32 clip_file_requested; /* bytes expected in the outstanding contents response */
 volatile UINT64 clip_file_last_activity; /* cliprdr thread writes, peer thread reads */
 rdp_clipboard_chunk_state clip_chunk;
 rdp_clipboard_descriptor *clip_file_stream_files;
 char authenticated_user[129], authenticated_domain[129];
 BOOL hash_supplied, drawn, echoed;
 UINT64 last_frame_generation, last_frame_id;
 BYTE *last_desktop;
 UINT32 last_desktop_width, last_desktop_height;
 BOOL force_full_frame;
 /* Per-peer frame-send scratch. Allocated once for the negotiated desktop and
  * reused for every frame: BITMAP_DATA entries point into encoded_buffer while
  * FreeRDP serialises a BitmapUpdate, so neither array may be reallocated or
  * freed mid-frame (2026-11-05 heap-use-after-free). */
 BITMAP_DATA *rectangles;
 UINT32 rectangle_capacity;
 BYTE *encoded_buffer;
 size_t encoded_capacity;
 /* Exact nearest-neighbour horizontal source-index cache for the case where
  * the agent capture size differs from the negotiated desktop size. */
 UINT32 *scale_x;
 UINT32 scale_x_width,scale_x_source_width;
 NSC_CONTEXT *nsc_encoder;
 wStream *nsc_stream;
 /* Client-driven resolution adaptation. The DISP channel context is created in
  * configure_peer and opened once PostConnect and DRDYNVC are ready. Its reader
  * thread only records a requested size and signals resize_event; the peer
  * thread performs the Deactivation-Reactivation so the transport is only
  * written from one thread. */
 DispServerContext *disp;
 HANDLE resize_event;
 BOOL disp_opened, disp_failed;
 /* Last (joined, dvc_ready, connected) tuple logged under RDP_DISP_DEBUG=1; no
  * effect unless that environment variable is set. */
 UINT32 disp_debug_state;
 /* Pending DISP monitor-layout request, written under options->mutex. */
 UINT32 resize_requested_width, resize_requested_height;
 /* Last frame layout logged for this peer (audit only). */
 UINT32 layout_source_width, layout_source_height;
 UINT32 layout_desktop_width, layout_desktop_height;
 UINT32 layout_content_width, layout_content_height;
 UINT32 layout_offset_x, layout_offset_y, layout_logged;
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
 RdpgfxServerContext *rdpgfx;
 rdp_avc_encoder *avc_encoder;
 rdp_gfx_runtime gfx_runtime;
 rdp_gfx_flow gfx_flow;
 rdp_gfx_ack_metrics gfx_ack_metrics;
#endif
} peer_context;
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
static BOOL peer_gfx_disable_before_surface(peer_context *ctx);
#endif

static int read_exact(int fd, BYTE *buffer, size_t length) {
 size_t offset=0;
 while (offset<length) {
  ssize_t n=recv(fd,buffer+offset,length-offset,0);
  if (n==0) return 0;
  if (n<0) {if (errno==EINTR) continue;return -1;}
  offset+=(size_t)n;
 }
 return 1;
}

static UINT16 read_be16(const BYTE *p) {return (UINT16)(((UINT16)p[0]<<8)|p[1]);}
static UINT32 read_be32(const BYTE *p) {return ((UINT32)p[0]<<24)|((UINT32)p[1]<<16)|((UINT32)p[2]<<8)|p[3];}
static UINT64 read_be64(const BYTE *p) {return ((UINT64)read_be32(p)<<32)|read_be32(p+4);}

static BOOL send_all_fd(int fd,const BYTE *data,size_t length) {
 size_t sent=0;
 while(sent<length) {
  ssize_t n=send(fd,data+sent,length-sent,0);
  if(n<0) {
   if(errno==EINTR) continue;
   /* SO_SNDTIMEO on the agent socket bounds this: an agent that stops reading
    * (for example because its input receiver thread died) used to block the
    * peer thread here forever while holding agent_mutex, which froze the
    * picture and left new sessions stuck before activation (2026-11-07). */
   if(errno==EAGAIN || errno==EWOULDBLOCK)
    fprintf(stderr,"event=agent_ipc_write_timeout errno=%d\n",errno);
   else
    fprintf(stderr,"event=agent_ipc_write_failed errno=%d\n",errno);
   fflush(stderr);
   return FALSE;
  }
  if(n==0) return FALSE;
  sent+=(size_t)n;
 }
 return TRUE;
}

static BOOL send_agent_message(server_options *options,UINT16 message_type,const BYTE *payload,UINT32 payload_size) {
 BYTE header[FRAME_IPC_HEADER]={0};
 memcpy(header,"RDPA",4);header[5]=1;header[6]=(BYTE)(message_type>>8);header[7]=(BYTE)message_type;
 header[8]=(BYTE)(payload_size>>24);header[9]=(BYTE)(payload_size>>16);
 header[10]=(BYTE)(payload_size>>8);header[11]=(BYTE)payload_size;
 pthread_mutex_lock(&options->agent_mutex);
 int fd=options->agent_client_fd;
 BOOL ok=fd>=0 && send_all_fd(fd,header,sizeof(header)) && send_all_fd(fd,payload,payload_size);
 pthread_mutex_unlock(&options->agent_mutex);
 return ok;
}

/* Opt-in C crash backtrace (RDP_WORKER_BACKTRACE=1). Go prints a Go-side dump,
 * but a SIGSEGV inside cgo loses the C frames; this handler prints the
 * backtrace (image names + offsets) before re-raising the signal. Off by
 * default so normal runs keep Go's native panic output. */
#include <execinfo.h>
#include <signal.h>

static void worker_crash_backtrace(int sig) {
 void *frames[64];
 int count=backtrace(frames,64);
 fprintf(stderr,"event=worker_crash signal=%d frames=%d\n",sig,count);fflush(stderr);
 backtrace_symbols_fd(frames,count,2);fflush(stderr);
 signal(sig,SIG_DFL);
 raise(sig);
}

static void install_worker_crash_backtrace(void) {
 const char *flag=getenv("RDP_WORKER_BACKTRACE");
 if (!flag || strcmp(flag,"1")!=0) return;
 struct sigaction action;
 memset(&action,0,sizeof(action));
 action.sa_handler=worker_crash_backtrace;
 sigemptyset(&action.sa_mask);
 action.sa_flags=SA_RESETHAND|SA_NODEFER;
 sigaction(SIGSEGV,&action,NULL);
 sigaction(SIGBUS,&action,NULL);
 sigaction(SIGILL,&action,NULL);
 sigaction(SIGABRT,&action,NULL);
 fprintf(stderr,"event=worker_backtrace_armed\n");fflush(stderr);
}

static BOOL send_agent_input(server_options *options,const BYTE *payload,UINT32 payload_size) { return send_agent_message(options,3,payload,payload_size);
}

static BOOL send_agent_clipboard_utf16(server_options *options,const BYTE *utf16,UINT32 length) {
 if(length>MAX_AGENT_IPC_PAYLOAD-1) return FALSE;
 BYTE *payload=malloc((size_t)length+1);
 if(!payload) return FALSE;
 payload[0]=2;memcpy(payload+1,utf16,length);
 BOOL ok=send_agent_message(options,8,payload,length+1);
 free(payload);
 return ok;
}

static BOOL send_key_event(peer_context *ctx,UINT16 flags,UINT16 code,UINT8 kind) {
 peer_job *job=ctx->context.peer ? ctx->context.peer->ContextExtra : NULL;
 if(!job) return FALSE;
 BYTE payload[9]={kind,(BYTE)(flags>>8),(BYTE)flags,(BYTE)(code>>8),(BYTE)code,0,0,0,0};
 return send_agent_input(job->options,payload,sizeof(payload));
}

static BOOL send_mouse_event(peer_context *ctx,UINT16 flags,UINT16 x,UINT16 y) {
 peer_job *job=ctx->context.peer ? ctx->context.peer->ContextExtra : NULL;
 if(!job) return FALSE;
 /* Work item A contract (DESIGN-2026-11-07-resolution-adaptation.md sections 3
  * and 5): the Agent maps DESKTOP coordinates into the capture (fit-with-bars)
  * and then onto the macOS display. The client's x/y are already desktop
  * coordinates, so forward them VERBATIM. Scaling them by the capture size here
  * (the pre-2026-11-08 behaviour) applied the fit ratio twice, so the cursor
  * drifted more the further it was from the centre: 100*2214/2560 = 86 was sent
  * instead of 100. Only clamp to the negotiated desktop bounds. */
 if(!ctx->width || !ctx->height) return FALSE;
 UINT32 dx=x,dy=y;
 if(dx>=ctx->width)dx=ctx->width-1;
 if(dy>=ctx->height)dy=ctx->height-1;
 BYTE payload[9]={1,(BYTE)(flags>>8),(BYTE)flags,0,0,
                  (BYTE)(dx>>8),(BYTE)dx,(BYTE)(dy>>8),(BYTE)dy};
 return send_agent_input(job->options,payload,sizeof(payload));
}

/* Worker -> Agent file clipboard messages (contract section 3, direction 1).
 * All fields are big-endian and every send is bounded by the agent socket send
 * timeout; a failed send aborts the offer without touching the peer transport. */
static BOOL send_agent_clipboard_file_offer_begin(server_options *options,UINT8 direction,
                                                  UINT16 file_count,UINT64 total_bytes) {
 BYTE payload[RDP_CLIPBOARD_IPC_BEGIN_BYTES];
 rdp_clipboard_offer_begin begin={0};
 begin.direction=direction;begin.file_count=file_count;begin.total_bytes=total_bytes;begin.flags=0;
 rdp_clipboard_write_offer_begin(payload,&begin);
 return send_agent_message(options,RDP_CLIPBOARD_IPC_TYPE_OFFER_BEGIN,payload,sizeof(payload));
}

static BOOL send_agent_clipboard_file_entry(server_options *options,
                                            const rdp_clipboard_entry *entry) {
 UINT32 length=rdp_clipboard_entry_wire_length(entry->name_length,entry->path_length);
 if(length>MAX_AGENT_IPC_PAYLOAD) return FALSE;
 BYTE *payload=malloc(length);
 if(!payload) return FALSE;
 rdp_clipboard_write_entry(payload,length,entry);
 BOOL ok=send_agent_message(options,RDP_CLIPBOARD_IPC_TYPE_ENTRY,payload,length);
 free(payload);
 return ok;
}

static BOOL send_agent_clipboard_file_chunk(server_options *options,UINT32 file_index,
                                            UINT64 offset,const BYTE *data,UINT32 length) {
 if(!data || length==0 || length>RDP_CLIPBOARD_IPC_MAX_CHUNK_BYTES) return FALSE;
 UINT32 payload_length=RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES+length;
 BYTE *payload=malloc(payload_length);
 if(!payload) return FALSE;
 rdp_clipboard_chunk chunk={0};
 chunk.file_index=file_index;chunk.offset=offset;chunk.data=data;chunk.data_length=length;
 rdp_clipboard_write_chunk(payload,payload_length,&chunk);
 BOOL ok=send_agent_message(options,RDP_CLIPBOARD_IPC_TYPE_CHUNK,payload,payload_length);
 free(payload);
 return ok;
}

static BOOL send_agent_clipboard_file_end(server_options *options,UINT8 direction,UINT8 status,
                                          UINT16 error_code,UINT32 file_count) {
 BYTE payload[RDP_CLIPBOARD_IPC_END_BYTES];
 rdp_clipboard_offer_end end={0};
 end.direction=direction;end.status=status;end.error_code=error_code;end.file_count=file_count;
 rdp_clipboard_write_offer_end(payload,&end);
 return send_agent_message(options,RDP_CLIPBOARD_IPC_TYPE_OFFER_END,payload,sizeof(payload));
}

/* Clipboard helpers implemented in the cliprdr section below. */
static void clipboard_agent_ipc_message(server_options *options,UINT16 message_type,
                                        const BYTE *payload,UINT32 payload_size);
static void clipboard_publish_local(server_options *options);
static void clipboard_local_files_free(rdp_clipboard_local_file *files,UINT32 count);

static BOOL private_agent_socket_path(const char *path) {
 if (!path || path[0]!='/' || strlen(path)>=sizeof(((struct sockaddr_un *)0)->sun_path)) return FALSE;
 char parent[sizeof(((struct sockaddr_un *)0)->sun_path)];
 memcpy(parent,path,strlen(path)+1);
 char *slash=strrchr(parent,'/');
 if (!slash || slash==parent) return FALSE;
 *slash='\0';
 struct stat info;
 if (stat(parent,&info)<0 || !S_ISDIR(info.st_mode) || info.st_uid!=geteuid() || (info.st_mode&0077))
  return FALSE;
 return TRUE;
}

static void *agent_connection(void *argument) {
 server_options *options=argument;
 int listener=-1;
 struct sockaddr_un address={0};
 listener=socket(AF_UNIX,SOCK_STREAM,0);
 if (listener<0) return NULL;
 address.sun_family=AF_UNIX;
 if (strlen(options->agent_socket)>=sizeof(address.sun_path)) {close(listener);return NULL;}
 memcpy(address.sun_path,options->agent_socket,strlen(options->agent_socket)+1);
 struct stat existing;
 if (lstat(options->agent_socket,&existing)==0 || errno!=ENOENT) {close(listener);return NULL;}
 if (bind(listener,(struct sockaddr *)&address,sizeof(address))<0) {close(listener);return NULL;}
 if (chmod(options->agent_socket,0600)<0 || listen(listener,1)<0) {
  close(listener);unlink(options->agent_socket);return NULL;
 }
 fprintf(stderr,"event=agent_ipc_listening path=%s\n",options->agent_socket);fflush(stderr);
 for (;;) {
  int client=accept(listener,NULL,NULL);
  if (client<0) {if(errno==EINTR) continue;break;}
  uid_t peer_uid=0;gid_t peer_gid=0;
  if (getpeereid(client,&peer_uid,&peer_gid)<0 || peer_uid!=geteuid()) {
   fprintf(stderr,"event=agent_ipc_rejected reason=peer_uid\n");close(client);continue;
  }
  int no_sigpipe=1;(void)setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&no_sigpipe,sizeof(no_sigpipe));
  /* Never let a stalled agent block a peer thread while holding agent_mutex. */
  {struct timeval send_timeout={0,500000};
   (void)setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&send_timeout,sizeof(send_timeout));}
  pthread_mutex_lock(&options->agent_mutex);
  if(options->agent_client_fd>=0) {
   pthread_mutex_unlock(&options->agent_mutex);close(client);continue;
  }
  options->agent_client_fd=client;
  pthread_mutex_unlock(&options->agent_mutex);
   /* A restarted Agent process reconnects at the display's native capture size.
    * Re-request the size negotiated by the active peer so it does not stay out
    * of sync (and pay per-frame scaling) until the next RDP connection. */
   UINT32 resync_width=0,resync_height=0;
   pthread_mutex_lock(&options->mutex);
   resync_width=options->requested_width;resync_height=options->requested_height;
   pthread_mutex_unlock(&options->mutex);
   if (resync_width && resync_height) {
    BYTE capture_size[8]={(BYTE)(resync_width>>24),(BYTE)(resync_width>>16),(BYTE)(resync_width>>8),(BYTE)resync_width,
                          (BYTE)(resync_height>>24),(BYTE)(resync_height>>16),(BYTE)(resync_height>>8),(BYTE)resync_height};
    if (send_agent_message(options,9,capture_size,sizeof(capture_size))) {
     fprintf(stderr,"event=agent_capture_size_resynced width=%u height=%u\n",resync_width,resync_height);
     fflush(stderr);
    }
   }
   BYTE *pending=NULL;UINT64 pending_generation=0,pending_id=0;UINT32 pending_width=0,pending_height=0;
   size_t pending_size=0,received=0;BOOL pending_delta=FALSE;
   /* Clipboard-file IPC types (13..16) and unknown future types must never kill
    * the Agent receiver (forward compatibility, contract section 3). Log the
    * first occurrence of each tolerated type only (types 0..127 tracked by
    * bitmap, anything above logged once per connection). */
   UINT64 ignored_types_mask=0;
   UINT64 ignored_types_mask_high=0;
   BOOL ignored_types_extreme_logged=FALSE;
   UINT32 pending_tile_count=0,received_tiles=0;
  for (;;) {
   BYTE header[FRAME_IPC_HEADER];
   int rc=read_exact(client,header,sizeof(header));
   if (rc<=0) break;
   if (memcmp(header,"RDPA",4)!=0 || read_be16(header+4)!=1) break;
   UINT16 type=read_be16(header+6);UINT32 payload_size=read_be32(header+8);
   if (payload_size>64u*1024u) break;
   BYTE *payload=malloc(payload_size ? payload_size : 1);
   if (!payload) break;
   rc=read_exact(client,payload,payload_size);
   if (rc<=0) {free(payload);break;}
   BOOL valid=TRUE;
   if (type==2 && payload_size==25) {
    UINT64 generation=read_be64(payload),frame_id=read_be64(payload+8);
    UINT32 width=read_be32(payload+16),height=read_be32(payload+20);UINT8 bpp=payload[24];
    UINT64 size=(UINT64)width*height*bpp;
    pthread_mutex_lock(&options->frame_mutex);
    BOOL stale=generation<options->frame_generation ||
      (generation==options->frame_generation && frame_id<=options->frame_id);
    pthread_mutex_unlock(&options->frame_mutex);
     free(pending);pending=NULL;received=0;pending_size=0;pending_delta=FALSE;
     pending_tile_count=0;received_tiles=0;
    if (stale || !generation || !frame_id || !width || !height || width>16384 || height>16384 ||
        bpp!=4 || size>MAX_FRAME_BYTES || size==0) valid=FALSE;
    else {
     pending=malloc((size_t)size);
     if (!pending) valid=FALSE;
     else {pending_generation=generation;pending_id=frame_id;pending_width=width;pending_height=height;pending_size=(size_t)size;}
    }
    } else if(type==10 && payload_size==29) {
     UINT64 generation=read_be64(payload),frame_id=read_be64(payload+8);
     UINT32 width=read_be32(payload+16),height=read_be32(payload+20);
     UINT8 bpp=payload[24];UINT32 tile_count=read_be32(payload+25);
     UINT64 size=(UINT64)width*height*bpp;
     UINT32 max_tiles=((width+63)/64)*((height+63)/64);
     pthread_mutex_lock(&options->frame_mutex);
     BOOL stale=generation<options->frame_generation ||
       (generation==options->frame_generation && frame_id<=options->frame_id);
     BOOL can_copy=options->frame_pixels && options->frame_generation==generation &&
       options->frame_width==width && options->frame_height==height;
     pthread_mutex_unlock(&options->frame_mutex);
     free(pending);pending=NULL;received=0;pending_size=0;pending_delta=FALSE;
     pending_tile_count=0;received_tiles=0;
     if(stale || !generation || !frame_id || !width || !height || width>16384 || height>16384 ||
        bpp!=4 || size==0 || size>MAX_FRAME_BYTES || !tile_count || tile_count>max_tiles) valid=FALSE;
     else {
      pending=malloc((size_t)size);
      if(!pending) valid=FALSE;
      else {
       if(can_copy) {
        pthread_mutex_lock(&options->frame_mutex);
        memcpy(pending,options->frame_pixels,(size_t)size);
        pthread_mutex_unlock(&options->frame_mutex);
       } else memset(pending,0,(size_t)size);
       pending_generation=generation;pending_id=frame_id;
       pending_width=width;pending_height=height;pending_size=(size_t)size;
       pending_delta=TRUE;pending_tile_count=tile_count;
      }
     }
    } else if(type==11 && payload_size>28) {
     UINT64 generation=read_be64(payload),frame_id=read_be64(payload+8);
     UINT32 x=read_be32(payload+16),y=read_be32(payload+20);
     UINT32 width=read_be16(payload+24),height=read_be16(payload+26);
     size_t tile_bytes=payload_size-28;
     UINT64 expected=(UINT64)width*height*4;
     if(!pending_delta || !pending || generation!=pending_generation || frame_id!=pending_id ||
        received_tiles>=pending_tile_count || !width || !height || width>64 || height>64 ||
        x%64 || y%64 || x>pending_width || y>pending_height ||
        width>pending_width-x || height>pending_height-y ||
        width!=(pending_width-x<64 ? pending_width-x : 64) ||
        height!=(pending_height-y<64 ? pending_height-y : 64) || expected!=tile_bytes) valid=FALSE;
     else {
      for(UINT32 row=0;row<height;row++) {
       size_t destination=((size_t)(y+row)*pending_width+x)*4;
       memcpy(pending+destination,payload+28+(size_t)row*width*4,(size_t)width*4);
      }
      received_tiles++;
     }
    } else if(type==12 && payload_size==20) {
     UINT64 generation=read_be64(payload),frame_id=read_be64(payload+8);
     UINT32 tile_count=read_be32(payload+16);
     if(!pending_delta || !pending || generation!=pending_generation || frame_id!=pending_id ||
        tile_count!=pending_tile_count || received_tiles!=pending_tile_count) valid=FALSE;
     else {
      pthread_mutex_lock(&options->frame_mutex);
      BYTE *old=options->frame_pixels;
      options->frame_pixels=pending;pending=NULL;
      options->frame_width=pending_width;options->frame_height=pending_height;
      options->frame_generation=pending_generation;options->frame_id=pending_id;
      pthread_mutex_unlock(&options->frame_mutex);
      free(old);
      pthread_mutex_lock(&options->mutex);
      for(unsigned i=0;i<MAX_PEERS;i++) {
       peer_job *job=options->jobs[i];
       if(job) SetEvent(job->frame_event);
      }
      pthread_mutex_unlock(&options->mutex);
      fprintf(stderr,"event=agent_frame_received generation=%llu frame_id=%llu width=%u height=%u bytes=%zu tiles=%u\n",
       (unsigned long long)pending_generation,(unsigned long long)pending_id,pending_width,pending_height,pending_size,tile_count);
      pending_delta=FALSE;pending_tile_count=0;received_tiles=0;
     }
    } else if (type==7 && payload_size>FRAME_CHUNK_HEADER) {
    UINT64 generation=read_be64(payload),frame_id=read_be64(payload+8);
    UINT32 offset=read_be32(payload+16);size_t chunk_size=payload_size-FRAME_CHUNK_HEADER;
    if (!pending || generation!=pending_generation || frame_id!=pending_id ||
        offset!=received || chunk_size>pending_size-received) valid=FALSE;
    else {
     memcpy(pending+received,payload+FRAME_CHUNK_HEADER,chunk_size);
     received+=chunk_size;
     if (received==pending_size) {
      pthread_mutex_lock(&options->frame_mutex);
      BYTE *old=options->frame_pixels;
      options->frame_pixels=pending;pending=NULL;
      options->frame_width=pending_width;options->frame_height=pending_height;
      options->frame_generation=pending_generation;options->frame_id=pending_id;
       pthread_mutex_unlock(&options->frame_mutex);
       free(old);
       pthread_mutex_lock(&options->mutex);
       for (unsigned i=0;i<MAX_PEERS;i++) {
        peer_job *job=options->jobs[i];
        if (job) SetEvent(job->frame_event);
       }
       pthread_mutex_unlock(&options->mutex);
      fprintf(stderr,"event=agent_frame_received generation=%llu frame_id=%llu width=%u height=%u bytes=%zu\n",
       (unsigned long long)pending_generation,(unsigned long long)pending_id,pending_width,pending_height,pending_size);
     }
    }
   } else if(type==8 && payload_size>=1 && payload[0]==1 && payload_size<=MAX_AGENT_IPC_PAYLOAD) {
    /* Local clipboard text (existing wire format): text replaces any local file
     * offer and is advertised to the RDP client as format 13. */
    UINT32 text_length=payload_size-1;
    BYTE *text=malloc(text_length ? text_length : 1);
    if(!text) valid=FALSE;
    else {
     if(text_length) memcpy(text,payload+1,text_length);
     pthread_mutex_lock(&options->clipboard_mutex);
     BYTE *old=options->clipboard_utf8;
     options->clipboard_utf8=text;options->clipboard_utf8_length=text_length;
     /* A text clipboard supersedes a local file clipboard. */
     clipboard_local_files_free(options->local_files,options->local_file_count);
     options->local_files=NULL;options->local_file_count=0;options->local_file_total_bytes=0;
     free(options->local_descriptors);options->local_descriptors=NULL;options->local_descriptors_length=0;
     pthread_mutex_unlock(&options->clipboard_mutex);
     free(old);
     fprintf(stderr,"event=clipboard_local_changed\n");fflush(stderr);
     clipboard_publish_local(options);
    }
   } else if(type==RDP_CLIPBOARD_IPC_TYPE_OFFER_BEGIN || type==RDP_CLIPBOARD_IPC_TYPE_CHUNK ||
             type==RDP_CLIPBOARD_IPC_TYPE_OFFER_END || type==RDP_CLIPBOARD_IPC_TYPE_ENTRY) {
    /* Worker <-> Agent file clipboard messages: validate, log and drop bad
     * payloads; never close the input receiver for a clipboard error. */
    clipboard_agent_ipc_message(options,type,payload,payload_size);
   } else if(type<=6 || type==8 || type==9 || type>=13) {
    /* Unused or unknown message type (or a malformed clipboard message): ignore
     * it and log once per type (contract section 3 forward compatibility). */
    if(type<64) {
     if(!(ignored_types_mask & (1ull<<type))) {
      ignored_types_mask |= (1ull<<type);
      fprintf(stderr,"event=agent_ipc_ignored type=%u\n",(unsigned)type);fflush(stderr);
     }
    } else if(type<128) {
     if(!(ignored_types_mask_high & (1ull<<(type-64)))) {
      ignored_types_mask_high |= (1ull<<(type-64));
      fprintf(stderr,"event=agent_ipc_ignored type=%u\n",(unsigned)type);fflush(stderr);
     }
    } else if(!ignored_types_extreme_logged) {
     ignored_types_extreme_logged=TRUE;
     fprintf(stderr,"event=agent_ipc_ignored type=%u\n",(unsigned)type);fflush(stderr);
    }
   } else valid=FALSE;
   free(payload);
   if (!valid) {fprintf(stderr,"event=agent_ipc_rejected reason=invalid_frame_message\n");break;}
  }
  free(pending);
  pthread_mutex_lock(&options->agent_mutex);
  if(options->agent_client_fd==client) options->agent_client_fd=-1;
  pthread_mutex_unlock(&options->agent_mutex);
  close(client);
 }
 close(listener);unlink(options->agent_socket);return NULL;
}

static BOOL peer_send_server_redirection_probe(freerdp_peer *peer,
                                               const rdpRedirection *redirection) {
 peer_job *job=peer ? peer->ContextExtra : NULL;
 fprintf(stderr,"event=server_redirection_callback invoked=1\n");fflush(stderr);
 return job && job->original_redirection ? job->original_redirection(peer,redirection) : FALSE;
}

int rdp_nt_hash(const char *password, unsigned char *hash) {
 if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 0;
 return NTOWFv1A(password, (UINT32)strlen(password), hash);
}

/* Size the per-peer frame-send scratch for the negotiated desktop. Raw tiles
 * consume exactly desktop_size bytes; planar RLE output is bounded by one
 * format byte plus four bytes per tile pixel, which sums to
 * desktop_size + tile_count. Buffers are only (re)allocated before any
 * rectangle references them, and are owned by peer_context. */
static BOOL peer_ensure_send_buffers(peer_context *ctx,BOOL raw_bitmap) {
 const UINT32 tile_count=((ctx->width+63)/64)*((ctx->height+63)/64);
 if (!ctx->width || !ctx->height || !tile_count) return FALSE;
 if (!ctx->rectangles || ctx->rectangle_capacity<tile_count) {
  BITMAP_DATA *rectangles=calloc(tile_count,sizeof(BITMAP_DATA));
  if (!rectangles) return FALSE;
  free(ctx->rectangles);ctx->rectangles=rectangles;ctx->rectangle_capacity=tile_count;
 }
 const size_t desktop_size=(size_t)ctx->width*ctx->height*4;
 const size_t encoded_needed=raw_bitmap ? desktop_size : desktop_size+(size_t)tile_count+64;
 if (!ctx->encoded_buffer || ctx->encoded_capacity<encoded_needed) {
  BYTE *buffer=malloc(encoded_needed);
  if (!buffer) return FALSE;
  free(ctx->encoded_buffer);ctx->encoded_buffer=buffer;ctx->encoded_capacity=encoded_needed;
 }
 return TRUE;
}
/* Client-driven resolution adaptation: negotiate the desktop size the server
 * advertises to the client. A request that fits the frame/IPC budget is used
 * verbatim (policy=client). Anything larger is scaled by one factor so the
 * aspect ratio is preserved, each dimension stays <= MAX_DESKTOP_DIM and the
 * total pixel count stays within DESKTOP_PIXEL_BUDGET (policy=clamp); both
 * dimensions are rounded down to an even number because Windows clients size
 * their window from these values. Never rejects a non-zero request. */
static BOOL peer_negotiate_size(UINT32 requested_width,UINT32 requested_height,
                                UINT32 *desktop_width,UINT32 *desktop_height,
                                const char **policy) {
 if (!requested_width || !requested_height) return FALSE;
 if (requested_width<=MAX_DESKTOP_DIM && requested_height<=MAX_DESKTOP_DIM &&
     (UINT64)requested_width*requested_height<=DESKTOP_PIXEL_BUDGET) {
  *desktop_width=requested_width;*desktop_height=requested_height;
  if (policy) *policy="client";
  return TRUE;
 }
 double factor=sqrt((double)DESKTOP_PIXEL_BUDGET/
                    ((double)requested_width*(double)requested_height));
 if (factor>(double)MAX_DESKTOP_DIM/(double)requested_width)
  factor=(double)MAX_DESKTOP_DIM/(double)requested_width;
 if (factor>(double)MAX_DESKTOP_DIM/(double)requested_height)
  factor=(double)MAX_DESKTOP_DIM/(double)requested_height;
 UINT32 width=(UINT32)((double)requested_width*factor);
 UINT32 height=(UINT32)((double)requested_height*factor);
 width&=~1u;height&=~1u;
 if (width<2) width=2; if (height<2) height=2;
 while ((UINT64)width*height>DESKTOP_PIXEL_BUDGET) {
  if (width>=height) {if (width>2) width-=2;} else {if (height>2) height-=2;}
  if (width==2 && height==2) break;
 }
 *desktop_width=width;*desktop_height=height;
 if (policy) *policy="clamp";
 return TRUE;
}

/* Fit-with-bars layout (shared formula with the Agent and the protocol tests):
 * scale a capture image into the desktop preserving its aspect ratio, centred,
 * with the remaining desktop pixels left black. Content dimensions are rounded
 * to nearest, offsets are floored. */
static void peer_fit_layout(UINT32 source_width,UINT32 source_height,
                            UINT32 desktop_width,UINT32 desktop_height,
                            UINT32 *content_width,UINT32 *content_height,
                            UINT32 *offset_x,UINT32 *offset_y) {
 UINT32 cw=0,ch=0,ox=0,oy=0;
 if (!source_width || !source_height || !desktop_width || !desktop_height) {
  *content_width=*content_height=*offset_x=*offset_y=0;
  return;
 }
 if ((UINT64)source_width*desktop_height<=(UINT64)desktop_width*source_height) {
  ch=desktop_height;
  UINT64 value=((UINT64)source_width*desktop_height+source_height/2)/source_height;
  cw=(UINT32)value;
  if (!cw) cw=1;
 } else {
  cw=desktop_width;
  UINT64 value=((UINT64)source_height*desktop_width+source_width/2)/source_width;
  ch=(UINT32)value;
  if (!ch) ch=1;
 }
 if (cw>desktop_width) cw=desktop_width;
 if (ch>desktop_height) ch=desktop_height;
 ox=(desktop_width-cw)/2;oy=(desktop_height-ch)/2;
 *content_width=cw;*content_height=ch;*offset_x=ox;*offset_y=oy;
}

/* Cache floor(x*source_width/content_width) for every content column so the
 * fit path does not run a variable 64-bit division per pixel. */
static BOOL peer_ensure_scale_x(peer_context *ctx,UINT32 content_width,UINT32 source_width) {
 if (!content_width || !source_width) return FALSE;
 if (ctx->scale_x && ctx->scale_x_width==content_width &&
     ctx->scale_x_source_width==source_width) return TRUE;
 UINT32 *table=malloc((size_t)content_width*sizeof(UINT32));
 if (!table) return FALSE;
 for (UINT32 x=0;x<content_width;x++)
  table[x]=(UINT32)(((UINT64)x*source_width)/content_width);
 free(ctx->scale_x);ctx->scale_x=table;
 ctx->scale_x_width=content_width;ctx->scale_x_source_width=source_width;
 return TRUE;
}

/* Copy the capture into the desktop with the fit layout, leaving the bars black.
 * Bars are pre-zeroed by the caller. Horizontal 1:1 uses one memcpy per row;
 * otherwise the cached scale_x table maps every content column. */
static BOOL peer_compose_fit(peer_context *ctx,BYTE *desktop,
                             const BYTE *source,UINT32 source_width,UINT32 source_height,
                             UINT32 desktop_width,UINT32 desktop_height,
                             UINT32 content_width,UINT32 content_height,
                             UINT32 offset_x,UINT32 offset_y) {
 if (!desktop || !source || !content_width || !content_height) return FALSE;
 if (content_width==source_width) {
  for (UINT32 y=0;y<content_height;y++) {
   UINT32 source_y=(UINT32)(((UINT64)y*source_height)/content_height);
   memcpy(desktop+(((size_t)(offset_y+y)*desktop_width+offset_x)*4),
          source+((size_t)source_y*source_width*4),(size_t)content_width*4);
  }
  return TRUE;
 }
 if (!peer_ensure_scale_x(ctx,content_width,source_width)) return FALSE;
 const UINT32 *scale_x=ctx->scale_x;
 for (UINT32 y=0;y<content_height;y++) {
  UINT32 source_y=(UINT32)(((UINT64)y*source_height)/content_height);
  const BYTE *source_row=source+((size_t)source_y*source_width*4);
  BYTE *destination_row=desktop+((size_t)(offset_y+y)*desktop_width+offset_x)*4;
  for (UINT32 x=0;x<content_width;x++) {
   const BYTE *pixel=source_row+((size_t)scale_x[x]*4);
   destination_row[(size_t)x*4]=pixel[0];
   destination_row[(size_t)x*4+1]=pixel[1];
   destination_row[(size_t)x*4+2]=pixel[2];
   destination_row[(size_t)x*4+3]=pixel[3];
  }
 }
 return TRUE;
}

/* Log the source/desktop/content geometry once per distinct tuple so a
 * resolution adaptation is auditable without per-frame log noise. */
static void peer_log_layout(peer_context *ctx,UINT32 source_width,UINT32 source_height,
                            UINT32 desktop_width,UINT32 desktop_height,
                            UINT32 content_width,UINT32 content_height,
                            UINT32 offset_x,UINT32 offset_y) {
 if (ctx->layout_logged &&
     ctx->layout_source_width==source_width && ctx->layout_source_height==source_height &&
     ctx->layout_desktop_width==desktop_width && ctx->layout_desktop_height==desktop_height &&
     ctx->layout_content_width==content_width && ctx->layout_content_height==content_height &&
     ctx->layout_offset_x==offset_x && ctx->layout_offset_y==offset_y) return;
 ctx->layout_logged=TRUE;
 ctx->layout_source_width=source_width;ctx->layout_source_height=source_height;
 ctx->layout_desktop_width=desktop_width;ctx->layout_desktop_height=desktop_height;
 ctx->layout_content_width=content_width;ctx->layout_content_height=content_height;
 ctx->layout_offset_x=offset_x;ctx->layout_offset_y=offset_y;
 fprintf(stderr,"event=peer_frame_layout source=%ux%u desktop=%ux%u content=%ux%u offset=%u,%u scaled=%u\n",
  source_width,source_height,desktop_width,desktop_height,content_width,content_height,
  offset_x,offset_y,
  (source_width!=content_width || source_height!=content_height) ? 1u : 0u);
 fflush(stderr);
}
static BOOL draw_pattern(freerdp_peer *peer) {
 peer_context *ctx = (peer_context *)peer->context;
 if (!ctx->leased || !ctx->ready) return FALSE;
 peer_job *job=peer->ContextExtra;
 if (!job) return FALSE;
 BYTE *source=NULL;UINT32 source_width=0,source_height=0;UINT64 source_generation=0,source_frame_id=0;
 pthread_mutex_lock(&job->options->frame_mutex);
 if (job->options->frame_pixels && job->options->frame_generation>0) {
  source_width=job->options->frame_width;source_height=job->options->frame_height;
  source_generation=job->options->frame_generation;source_frame_id=job->options->frame_id;
  size_t source_size=(size_t)source_width*source_height*4;
  source=malloc(source_size);
  if (source) memcpy(source,job->options->frame_pixels,source_size);
 }
 pthread_mutex_unlock(&job->options->frame_mutex);
 if (source_frame_id && !source) return FALSE;
 if (!source && !job->options->test_pattern) return FALSE;
 size_t desktop_size=(size_t)ctx->width*ctx->height*4;
 BYTE *desktop=source;
 if (source) {
  UINT32 content_width=0,content_height=0,offset_x=0,offset_y=0;
  peer_fit_layout(source_width,source_height,ctx->width,ctx->height,
                  &content_width,&content_height,&offset_x,&offset_y);
  peer_log_layout(ctx,source_width,source_height,ctx->width,ctx->height,
                  content_width,content_height,offset_x,offset_y);
  /* The capture may fit the desktop exactly (same aspect and size) only when the
   * source already IS the desktop: uniform scaling keeps content==desktop with
   * zero offsets, so comparing content against the desktop is not enough. */
  if (source_width!=ctx->width || source_height!=ctx->height ||
      offset_x || offset_y || content_width!=source_width ||
      content_height!=source_height) {
   /* Fit-with-bars: compose the capture into a black desktop, centred, with the
    * capture aspect preserved. This is never a non-uniform stretch, so a client
    * that selected a different aspect ratio sees black bars instead of
    * distortion. When the capture already fills the desktop the source buffer
    * is used directly (zero copy). */
   desktop=malloc(desktop_size);
   if (!desktop) {free(source);return FALSE;}
   memset(desktop,0,desktop_size);
   if (!peer_compose_fit(ctx,desktop,source,source_width,source_height,
                         ctx->width,ctx->height,content_width,content_height,
                         offset_x,offset_y)) {
    free(desktop);free(source);return FALSE;
   }
  }
 }
 if (!desktop) {
  desktop=malloc(desktop_size);
  if (!desktop) return FALSE;
  const char *stress_setting=getenv("RDP_TEST_STRESS_FRAME");
  BOOL stress_frame=stress_setting && strcmp(stress_setting,"1")==0;
  for (UINT32 y=0;y<ctx->height;y++) for (UINT32 x=0;x<ctx->width;x++) {
   size_t n=((size_t)y*ctx->width+x)*4;
   desktop[n]=(ctx->inputs&3)==3 ? 0x80 : 0x20;
   if (stress_frame) {
    UINT32 noise=(x*0x45d9f3bU)^(y*0x119de1f3U);
    noise^=noise>>16;noise*=0x45d9f3bU;noise^=noise>>16;
    desktop[n+1]=(BYTE)noise;desktop[n+2]=(BYTE)(noise>>8);
   } else {
    desktop[n+1]=x<ctx->width/2 ? 0xa0 : 0x40;
    desktop[n+2]=y<ctx->height/2 ? 0x30 : 0xc0;
   }
   desktop[n+3]=0;
  }
 }
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
 rdp_gfx_frame_action gfx_action=rdp_gfx_runtime_frame_action(&ctx->gfx_runtime,
  rdp_gfx_can_send(&ctx->gfx_flow));
 if (gfx_action==RDP_GFX_FRAME_DROP) {
  rdp_gfx_request_refresh(&ctx->gfx_flow);
  if (source_frame_id) {ctx->last_frame_generation=source_generation;ctx->last_frame_id=source_frame_id;}
  if (desktop!=source) free(desktop);free(source);
  return TRUE;
 }
 if (gfx_action==RDP_GFX_FRAME_SETUP && (!ctx->rdpgfx || !ctx->avc_encoder)) {
  if (rdp_gfx_runtime_can_fallback_raw(&ctx->gfx_runtime) && peer_gfx_disable_before_surface(ctx))
   gfx_action=RDP_GFX_FRAME_RAW;
  else gfx_action=RDP_GFX_FRAME_FATAL;
 }
 if (gfx_action==RDP_GFX_FRAME_SETUP || gfx_action==RDP_GFX_FRAME_SEND) {
  const uint8_t *annexb=NULL;size_t annexb_length=0;int64_t pts=-1;
  int encoded=rdp_avc_encoder_encode(ctx->avc_encoder,desktop,desktop_size,
   (size_t)ctx->width*4,&annexb,&annexb_length,&pts);
  (void)pts;
  if (encoded<0) gfx_action=RDP_GFX_FRAME_FATAL;
  else if (encoded==0 && gfx_action==RDP_GFX_FRAME_SETUP) {
   rdp_gfx_request_refresh(&ctx->gfx_flow);
   gfx_action=RDP_GFX_FRAME_RAW;
  } else if (encoded==0) {
   rdp_gfx_request_refresh(&ctx->gfx_flow);
   if (source_frame_id) {ctx->last_frame_generation=source_generation;ctx->last_frame_id=source_frame_id;}
   if (desktop!=source) free(desktop);free(source);
   return TRUE;
  } else if (gfx_action==RDP_GFX_FRAME_SETUP) {
   if (rdp_gfx_send_first_avc420_frame(&ctx->gfx_runtime,ctx->rdpgfx,&ctx->gfx_flow,
       0,ctx->width,ctx->height,annexb,annexb_length,(uint32_t)GetTickCount64())) {
    if (source_frame_id) {ctx->last_frame_generation=source_generation;ctx->last_frame_id=source_frame_id;}
    fprintf(stderr,"event=gfx_avc420_frame_sent frame_id=%u bytes=%zu pending=%u\n",
     ctx->gfx_flow.next_frame_id,annexb_length,ctx->gfx_flow.pending);
    fflush(stderr);
    if (desktop!=source) free(desktop);free(source);
    return TRUE;
   }
   if (rdp_gfx_runtime_can_fallback_raw(&ctx->gfx_runtime) && peer_gfx_disable_before_surface(ctx))
    gfx_action=RDP_GFX_FRAME_RAW;
   else gfx_action=RDP_GFX_FRAME_FATAL;
  } else if (!rdp_gfx_send_avc420_frame(ctx->rdpgfx,&ctx->gfx_flow,0,ctx->width,ctx->height,
             annexb,annexb_length,(uint32_t)GetTickCount64()))
   gfx_action=RDP_GFX_FRAME_FATAL;
  else {
   if (source_frame_id) {ctx->last_frame_generation=source_generation;ctx->last_frame_id=source_frame_id;}
   fprintf(stderr,"event=gfx_avc420_frame_sent frame_id=%u bytes=%zu pending=%u\n",
    ctx->gfx_flow.next_frame_id,annexb_length,ctx->gfx_flow.pending);
   fflush(stderr);
   if (desktop!=source) free(desktop);free(source);
   return TRUE;
  }
 }
 if (gfx_action==RDP_GFX_FRAME_RAW && ctx->gfx_runtime.phase==RDP_GFX_RUNTIME_FAILED &&
     (ctx->rdpgfx || ctx->avc_encoder) && !peer_gfx_disable_before_surface(ctx))
  gfx_action=RDP_GFX_FRAME_FATAL;
 if (gfx_action==RDP_GFX_FRAME_FATAL) {
  if (desktop!=source) free(desktop);free(source);
  return FALSE;
 }
#endif
 UINT32 columns=(ctx->width+63)/64,rows=(ctx->height+63)/64;
 UINT64 tile_count64=(UINT64)columns*rows;
 if (!tile_count64 || tile_count64>UINT32_MAX) {if(desktop!=source)free(desktop);free(source);return FALSE;}
 const char *stress_setting=getenv("RDP_TEST_STRESS_FRAME");
 BOOL stress_frame=stress_setting && strcmp(stress_setting,"1")==0;
  const char *raw_setting=getenv("RDP_TEST_RAW_BITMAP");
   BOOL raw_bitmap=raw_setting && strcmp(raw_setting,"1")==0;
   const char *nsc_setting=getenv("RDP_TEST_NSCODEC_BITMAP");
   BOOL nsc_bitmap=nsc_setting && strcmp(nsc_setting,"1")==0 &&
     freerdp_settings_get_bool(peer->context->settings,FreeRDP_NSCodec) &&
     freerdp_settings_get_uint32(peer->context->settings,FreeRDP_NSCodecId)>0;
   if (nsc_bitmap && (!ctx->nsc_encoder || !ctx->nsc_stream)) {
    ctx->nsc_encoder=nsc_context_new();
    ctx->nsc_stream=Stream_New(NULL,65536);
    if (!ctx->nsc_encoder || !ctx->nsc_stream ||
        !nsc_context_set_parameters(ctx->nsc_encoder,NSC_COLOR_FORMAT,PIXEL_FORMAT_BGRA32) ||
        !nsc_context_set_parameters(ctx->nsc_encoder,NSC_COLOR_LOSS_LEVEL,1) ||
        !nsc_context_set_parameters(ctx->nsc_encoder,NSC_ALLOW_SUBSAMPLING,0)) {
     if(ctx->nsc_encoder){nsc_context_free(ctx->nsc_encoder);ctx->nsc_encoder=NULL;}
     if(ctx->nsc_stream){Stream_Free(ctx->nsc_stream,TRUE);ctx->nsc_stream=NULL;}
     if(desktop!=source)free(desktop);free(source);return FALSE;
    }
   }
   /* Live agent frames are diffed against the previously sent desktop for all
    * encodings (raw, nscodec, planar). Test-pattern frames (source==NULL) stay
    * full-frame, matching the original raw/nscodec behaviour. */
   const BYTE *previous=(source && !ctx->force_full_frame && ctx->last_desktop &&
    ctx->last_desktop_width==ctx->width && ctx->last_desktop_height==ctx->height)
    ? ctx->last_desktop : NULL;
  if (!peer_ensure_send_buffers(ctx,raw_bitmap)) {
   if(desktop!=source)free(desktop);free(source);return FALSE;
  }
  BITMAP_DATA *rectangles=ctx->rectangles;
  BYTE *encoded_all=ctx->encoded_buffer;
  const size_t encoded_length_limit=ctx->encoded_capacity;
  size_t encoded_length=0;
 BITMAP_PLANAR_CONTEXT *encoder=freerdp_bitmap_planar_context_new(PLANAR_FORMAT_HEADER_RLE,64,64);
 if (!encoder) {if(desktop!=source)free(desktop);free(source);return FALSE;}
  BOOL ok=TRUE;
  UINT32 tile_index=0,batch_start=0,batch_count=0;
  const UINT32 batch_rect_limit=BITMAP_BATCH_RECT_LIMIT;
 for (UINT32 top=0;top<ctx->height && ok;top+=64) {
  UINT32 tile_height=ctx->height-top;if(tile_height>64)tile_height=64;
    for (UINT32 left=0;left<ctx->width;left+=64) {
      UINT32 tile_width=ctx->width-left;if(tile_width>64)tile_width=64;
      if (previous && !rdp_tile_changed(desktop,previous,ctx->width,left,top,tile_width,tile_height)) continue;
     if (nsc_bitmap) {
      Stream_Clear(ctx->nsc_stream);Stream_ResetPosition(ctx->nsc_stream);
      if (!nsc_compose_message(ctx->nsc_encoder,ctx->nsc_stream,
          desktop+(((size_t)top*ctx->width+left)*4),tile_width,tile_height,ctx->width*4)) {ok=FALSE;break;}
      SURFACE_BITS_COMMAND command={0};
      command.cmdType=CMDTYPE_SET_SURFACE_BITS;
      command.destLeft=left;command.destTop=top;
      command.destRight=left+tile_width;command.destBottom=top+tile_height;
      command.bmp.bpp=32;command.bmp.codecID=(UINT16)freerdp_settings_get_uint32(peer->context->settings,FreeRDP_NSCodecId);
      command.bmp.width=tile_width;command.bmp.height=tile_height;
      command.bmp.bitmapDataLength=(UINT32)Stream_GetPosition(ctx->nsc_stream);
      command.bmp.bitmapData=Stream_Buffer(ctx->nsc_stream);command.skipCompression=TRUE;
      ok=peer->context->update->SurfaceBits(peer->context,&command);
      tile_index++;batch_count++;
      if(!ok)break;
      continue;
     }
     BYTE encoded[64*1024];UINT32 tile_length=sizeof(encoded);
    if(raw_bitmap) {
     tile_length=tile_width*tile_height*4;
     for(UINT32 row=0;row<tile_height;row++) {
      const BYTE *src=desktop+(((size_t)(top+tile_height-1-row)*ctx->width+left)*4);
      memcpy(encoded+((size_t)row*tile_width*4),src,tile_width*4);
     }
    } else {
     if (!freerdp_bitmap_planar_context_reset(encoder,tile_width,tile_height)) {ok=FALSE;break;}
     BYTE *compressed=freerdp_bitmap_compress_planar(encoder,
        desktop+(((size_t)top*ctx->width+left)*4),PIXEL_FORMAT_BGRX32,
        tile_width,tile_height,ctx->width*4,encoded,&tile_length);
     if (!compressed) {ok=FALSE;break;}
    }
    /* encoded_buffer is sized for the worst case up front, so nothing is
     * reallocated while previously built BITMAP_DATA entries reference it. */
    if(encoded_length+tile_length>encoded_length_limit) {ok=FALSE;break;}
   BITMAP_DATA *data=&rectangles[tile_index++];
   data->destLeft=left;data->destTop=top;data->destRight=left+tile_width-1;
   data->destBottom=top+tile_height-1;data->width=tile_width;data->height=tile_height;
   data->bitsPerPixel=32;data->bitmapLength=tile_length;data->cbCompFirstRowSize=0;
   data->cbCompMainBodySize=tile_length;data->cbScanWidth=tile_width*4;
   data->cbUncompressedSize=tile_width*tile_height*4;
    data->bitmapDataStream=encoded_all+encoded_length;data->compressed=raw_bitmap ? FALSE : TRUE;
   memcpy(data->bitmapDataStream,encoded,tile_length);encoded_length+=tile_length;
     if(tile_index-batch_start>=batch_rect_limit) {
    BITMAP_UPDATE update={0};update.number=tile_index-batch_start;
    update.rectangles=&rectangles[batch_start];update.skipCompression=TRUE;
    ok=peer->context->update->BitmapUpdate(peer->context,&update);
    batch_count++;
    if(ok && stress_frame) {
     for(unsigned repeat=0;repeat<16;repeat++)
      if(!peer->context->update->BitmapUpdate(peer->context,&update)){ok=FALSE;break;}
    }
    batch_start=tile_index;
    if(!ok) break;
   }
  }
 }
  if(ok) {
  if(batch_start<tile_index) {
   BITMAP_UPDATE update={0};update.number=tile_index-batch_start;
   update.rectangles=&rectangles[batch_start];update.skipCompression=TRUE;
   ok=peer->context->update->BitmapUpdate(peer->context,&update);
   batch_count++;
   if(ok && stress_frame) {
    /* Deliberately exceed socket buffering only in deadline regression tests. */
    for(unsigned repeat=0;repeat<16;repeat++)
     if(!peer->context->update->BitmapUpdate(peer->context,&update)){ok=FALSE;break;}
   }
  }
 } else ok=FALSE;
  freerdp_bitmap_planar_context_free(encoder);
   if (ok && source) {
   BYTE *saved=malloc(desktop_size);
   if (saved) memcpy(saved,desktop,desktop_size);
   free(ctx->last_desktop);
   ctx->last_desktop=saved;
   ctx->last_desktop_width=ctx->width;ctx->last_desktop_height=ctx->height;
   ctx->force_full_frame=FALSE;
  }
 if(desktop!=source)free(desktop);
 free(source);
 if (ok && source_frame_id) {
   ctx->last_frame_generation=source_generation;
   ctx->last_frame_id=source_frame_id;
    fprintf(stderr,"event=desktop_frame_sent generation=%llu frame_id=%llu batches=%u tiles=%u bytes=%zu pdus=%u encoding=%s\n",
      (unsigned long long)source_generation,(unsigned long long)source_frame_id,batch_count,tile_index,encoded_length,batch_count,
      nsc_bitmap ? "nscodec" : raw_bitmap ? "raw" : "planar");
   fflush(stderr);
  }
  return ok;
}
static UINT64 latest_frame_id(peer_job *job) {
 if (!job) return 0;
 pthread_mutex_lock(&job->options->frame_mutex);
 UINT64 frame_id=job->options->frame_id;
 pthread_mutex_unlock(&job->options->frame_mutex);
 return frame_id;
}
static BOOL draw_pattern_with_deadline(freerdp_peer *peer) {
 peer_job *job=peer->ContextExtra;
 if (!job) return FALSE;
 pthread_mutex_lock(&job->options->mutex);
 if (job->cancelled) {pthread_mutex_unlock(&job->options->mutex);return FALSE;}
 job->deadline=GetTickCount64()+5000;
 pthread_mutex_unlock(&job->options->mutex);
 BOOL ok=draw_pattern(peer);
 pthread_mutex_lock(&job->options->mutex);
 if (!job->cancelled) job->deadline=UINT64_MAX;
 pthread_mutex_unlock(&job->options->mutex);
 return ok;
}

static BOOL identity_ascii(const SEC_WINNT_AUTH_IDENTITY *identity, char u[129], char d[129]) {
 UINT32 user_len=0, domain_len=0;
 memset(u,0,129);memset(d,0,129);
 if (sspi_GetAuthIdentityFlags(identity) & SEC_WINNT_AUTH_IDENTITY_UNICODE) {
  const WCHAR *user=NULL,*domain=NULL;
  if (!sspi_GetAuthIdentityUserDomainW(identity,&user,&user_len,&domain,&domain_len) ||
      !user || !user_len || user_len>128 || domain_len>128 || (domain_len && !domain)) return FALSE;
  for (UINT32 i=0;i<user_len;i++) {if (user[i]>127) return FALSE;u[i]=(char)user[i];}
  for (UINT32 i=0;i<domain_len;i++) {if (domain[i]>127) return FALSE;d[i]=(char)domain[i];}
 } else if (sspi_GetAuthIdentityFlags(identity) & SEC_WINNT_AUTH_IDENTITY_ANSI) {
  const char *user=NULL,*domain=NULL;
  if (!sspi_GetAuthIdentityUserDomainA(identity,&user,&user_len,&domain,&domain_len) ||
      !user || !user_len || user_len>128 || domain_len>128 || (domain_len && !domain)) return FALSE;
  memcpy(u,user,user_len);if (domain_len) memcpy(d,domain,domain_len);
 } else return FALSE;
 return strlen(u)==user_len && strlen(d)==domain_len;
}

/* Capture the principal from the NTLM authentication exchange, not from
 * client-supplied delegated TSCredentials. WinPR still computes and verifies
 * the complete NTLM proof, MIC and CredSSP channel binding. */
static SECURITY_STATUS ntlm_hash(void *argument,const SEC_WINNT_AUTH_IDENTITY *identity,
 const SecBuffer *proof,const BYTE *random,const BYTE *mic,const SecBuffer *mic_value,BYTE *hash) {
 (void)proof;(void)random;(void)mic;(void)mic_value;
 freerdp_peer *peer=argument;
 peer_context *ctx=(peer_context *)peer->context;
 char u[129],d[129],lookup[129];
 ctx->hash_supplied=FALSE;
 if (!identity_ascii(identity,u,d) || (d[0] && strcasecmp(d,"MACRDP"))) return SEC_E_LOGON_DENIED;
 const char *bare=u;
 if (!strncasecmp(u,"MACRDP\\",7)) bare=u+7;
 for (size_t i=0;i<=strlen(bare);i++) lookup[i]=(char)tolower((unsigned char)bare[i]);
 peer_job *job=peer->ContextExtra;
 WINPR_SAM *sam=SamOpen(job->options->sam,TRUE);
 if (!sam) return SEC_E_NO_CREDENTIALS;
 WINPR_SAM_ENTRY *entry=SamLookupUserA(sam,lookup,(UINT32)strlen(lookup),"MACRDP",6);
 BOOL ok=entry && NTOWFv2FromHashA(entry->NtHash,u,(UINT32)strlen(u),d,(UINT32)strlen(d),hash);
 if (entry) SamFreeEntry(sam,entry);
 SamClose(sam);
 if (!ok) return SEC_E_LOGON_DENIED;
 memcpy(ctx->authenticated_user,u,sizeof(u));memcpy(ctx->authenticated_domain,d,sizeof(d));
 ctx->hash_supplied=TRUE;
 return SEC_E_OK;
}
static BOOL peer_logon(freerdp_peer *peer,const SEC_WINNT_AUTH_IDENTITY *identity,BOOL automatic) {
 (void)identity;
 peer_context *ctx=(peer_context *)peer->context;
 if (!automatic) {fprintf(stderr,"event=peer_logon_rejected reason=non_automatic\n");fflush(stderr);return FALSE;}
 if (!ctx->hash_supplied) {fprintf(stderr,"event=peer_logon_rejected reason=no_verified_hash\n");fflush(stderr);return FALSE;}
 UINT64 lease_token=goAuthorize(ctx->authenticated_user,ctx->authenticated_domain);
 if (!lease_token) {fprintf(stderr,"event=peer_logon_rejected reason=authorization_denied\n");fflush(stderr);return FALSE;}
 ctx->leased=TRUE;ctx->lease_token=lease_token;ctx->next_heartbeat=0;
 /* The delegated password is unnecessary for a test pattern or desktop
  * authorization. Clear the settings copy immediately; never inspect it. */
 BOOL cleared=freerdp_settings_set_string(peer->context->settings,FreeRDP_Password,NULL);
 fprintf(stderr,"event=peer_logon_complete password_cleared=%u\n",cleared);fflush(stderr);
 return cleared;
}
/* Read the requested desktop size from the peer settings, negotiate it against
 * the frame/IPC budget and write the negotiated size back before Demand Active is
 * sent. FreeRDP invokes this once before every Demand Active (initial connection
 * and each Deactivation-Reactivation), so the client is always told the size the
 * worker will actually serve. */
static BOOL peer_capabilities(freerdp_peer *peer) {
 peer_context *ctx=(peer_context *)peer->context;
 UINT32 requested_width=freerdp_settings_get_uint32(peer->context->settings,FreeRDP_DesktopWidth);
 UINT32 requested_height=freerdp_settings_get_uint32(peer->context->settings,FreeRDP_DesktopHeight);
 UINT32 width=0,height=0;const char *policy="client";
 if (!peer_negotiate_size(requested_width,requested_height,&width,&height,&policy)) {
  fprintf(stderr,"event=peer_capabilities_rejected reason=invalid_size width=%u height=%u\n",
   requested_width,requested_height);fflush(stderr);
  return FALSE;
 }
 if (width!=requested_width || height!=requested_height) {
  if (!freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopWidth,width) ||
      !freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopHeight,height)) return FALSE;
 }
 ctx->width=width;ctx->height=height;
 fprintf(stderr,"event=peer_size_negotiated requested=%ux%u desktop=%ux%u policy=%s\n",
  requested_width,requested_height,width,height,policy);fflush(stderr);
 return TRUE;
}

/* DISP diagnostics (Issue 1, 2026-11-08). Monotonic millisecond timestamp for
 * every DISP audit line, and an opt-in RDP_DISP_DEBUG=1 extra line. Neither
 * allocates nor changes control flow; default output is unchanged apart from
 * the extra fields appended to the existing event= lines. */
static unsigned long long disp_now_ms(void) {
 return (unsigned long long)GetTickCount64();
}
static BOOL disp_debug_enabled(void) {
 const char *value=getenv("RDP_DISP_DEBUG");
 return value && value[0]=='1';
}
/* ChannelIdAssigned is invoked synchronously by DispServerContext->Open() and
 * carries the dynamic virtual channel id the DRDYNVC bound the DISP channel to.
 * Returning FALSE would make Open fail, so it must always return TRUE. */
static BOOL peer_disp_channel_id_assigned(DispServerContext *disp, UINT32 channelId) {
 (void)disp;
 fprintf(stderr,"event=disp_channel_id_assigned id=%u ts_ms=%llu\n",
  channelId,disp_now_ms());fflush(stderr);
 return TRUE;
}

/* DISP monitor-layout callback. Runs on the DISP channel reader thread: record
 * the bounding box of the requested monitors and wake the peer thread, which is
 * the only thread allowed to write the RDP transport. */
static UINT peer_disp_monitor_layout(DispServerContext *disp,
                                     const DISPLAY_CONTROL_MONITOR_LAYOUT_PDU *pdu) {
 if (!disp || !pdu) return ERROR_INVALID_DATA;
 peer_context *ctx=(peer_context *)disp->custom;
 if (!ctx || !ctx->context.peer) return ERROR_INVALID_DATA;
 peer_job *job=ctx->context.peer->ContextExtra;
 if (!job) return ERROR_INVALID_DATA;
 if (!pdu->NumMonitors || !pdu->Monitors) return ERROR_INVALID_DATA;
 INT64 left=pdu->Monitors[0].Left,top=pdu->Monitors[0].Top;
 INT64 right=left+(INT64)pdu->Monitors[0].Width;
 INT64 bottom=top+(INT64)pdu->Monitors[0].Height;
 for (UINT32 i=1;i<pdu->NumMonitors;i++) {
  const DISPLAY_CONTROL_MONITOR_LAYOUT *monitor=&pdu->Monitors[i];
  if ((INT64)monitor->Left<left) left=monitor->Left;
  if ((INT64)monitor->Top<top) top=monitor->Top;
  if ((INT64)monitor->Left+(INT64)monitor->Width>right) right=(INT64)monitor->Left+(INT64)monitor->Width;
  if ((INT64)monitor->Top+(INT64)monitor->Height>bottom) bottom=(INT64)monitor->Top+(INT64)monitor->Height;
 }
 if (right<=left || bottom<=top) return ERROR_INVALID_DATA;
 const DISPLAY_CONTROL_MONITOR_LAYOUT *first=&pdu->Monitors[0];
 fprintf(stderr,"event=disp_monitor_layout requested=%ux%u monitors=%u ts_ms=%llu "
  "left=%d top=%d width=%u height=%u flags=0x%08x dscale=%u devscale=%u\n",
  (unsigned)(right-left),(unsigned)(bottom-top),pdu->NumMonitors,disp_now_ms(),
  (int)first->Left,(int)first->Top,first->Width,first->Height,first->Flags,
  first->DesktopScaleFactor,first->DeviceScaleFactor);
 if (disp_debug_enabled()) {
  for (UINT32 i=1;i<pdu->NumMonitors;i++) {
   const DISPLAY_CONTROL_MONITOR_LAYOUT *monitor=&pdu->Monitors[i];
   fprintf(stderr,"event=disp_debug_monitor index=%u left=%d top=%d width=%u height=%u "
    "flags=0x%08x dscale=%u devscale=%u\n",
    i,(int)monitor->Left,(int)monitor->Top,monitor->Width,monitor->Height,
    monitor->Flags,monitor->DesktopScaleFactor,monitor->DeviceScaleFactor);
  }
 }
 fflush(stderr);
 pthread_mutex_lock(&job->options->mutex);
 ctx->resize_requested_width=(UINT32)(right-left);
 ctx->resize_requested_height=(UINT32)(bottom-top);
 pthread_mutex_unlock(&job->options->mutex);
 if (ctx->resize_event) SetEvent(ctx->resize_event);
 return CHANNEL_RC_OK;
}

/* Peer-thread half of a client-driven resize: negotiate, publish the new size in
 * the settings and run the Deactivation-Reactivation. peer_activate then re-sends
 * the capture-size request to the Agent and forces a full repaint. */
static BOOL peer_handle_pending_resize(freerdp_peer *peer) {
 peer_context *ctx=(peer_context *)peer->context;
 peer_job *job=peer->ContextExtra;
 if (!ctx || !job) return FALSE;
 UINT32 requested_width=0,requested_height=0;
 pthread_mutex_lock(&job->options->mutex);
 requested_width=ctx->resize_requested_width;
 requested_height=ctx->resize_requested_height;
 ctx->resize_requested_width=ctx->resize_requested_height=0;
 pthread_mutex_unlock(&job->options->mutex);
 if (!requested_width || !requested_height) return TRUE;
 if (requested_width==ctx->width && requested_height==ctx->height) {
  fprintf(stderr,"event=peer_resize_ignored reason=unchanged width=%u height=%u\n",
   requested_width,requested_height);fflush(stderr);
  return TRUE;
 }
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
 /* GFX/AVC420 surfaces are sized and mapped for the session geometry; a
  * mid-session resize would need a GFX ResetGraphics/surface re-create (follow-up
  * in the design doc). Keep the current size rather than corrupting a mapped
  * surface: the client sees the resize ignored, not a broken session. */
 if (ctx->gfx_runtime.phase!=RDP_GFX_RUNTIME_RAW &&
     ctx->gfx_runtime.phase!=RDP_GFX_RUNTIME_FAILED) {
  fprintf(stderr,"event=peer_resize_ignored reason=gfx_active requested=%ux%u\n",
   requested_width,requested_height);fflush(stderr);
  return TRUE;
 }
#endif
 UINT32 width=0,height=0;const char *policy="client";
 if (!peer_negotiate_size(requested_width,requested_height,&width,&height,&policy)) {
  fprintf(stderr,"event=peer_resize_rejected reason=invalid_size width=%u height=%u\n",
   requested_width,requested_height);fflush(stderr);
  return TRUE;
 }
 if (!peer->context->update || !peer->context->update->DesktopResize) return FALSE;
 if (!freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopWidth,width) ||
     !freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopHeight,height)) return FALSE;
 ctx->width=width;ctx->height=height;
 /* No bitmap updates while the Deactivation-Reactivation handshake runs. */
 ctx->ready=FALSE;
 ctx->force_full_frame=TRUE;
 ctx->drawn=FALSE;
 ctx->layout_logged=FALSE;
 fprintf(stderr,"event=peer_reactivate requested=%ux%u desktop=%ux%u policy=%s\n",
  requested_width,requested_height,width,height,policy);fflush(stderr);
 if (!peer->context->update->DesktopResize(peer->context)) {
  fprintf(stderr,"event=peer_reactivate_failed requested=%ux%u desktop=%ux%u\n",
   requested_width,requested_height,width,height);fflush(stderr);
  return FALSE;
 }
 return TRUE;
}

static BOOL peer_activate(freerdp_peer *peer) {
 peer_context *ctx=(peer_context *)peer->context;
 fprintf(stderr,"event=peer_activate_started leased=%u ready=%u\n",ctx->leased,ctx->ready);fflush(stderr);
 if (!ctx->leased) {fprintf(stderr,"event=peer_activate_rejected reason=not_leased\n");fflush(stderr);return FALSE;}
 peer_job *job=peer->ContextExtra;
 if (!job->options->test_pattern && latest_frame_id(job)==0) {fprintf(stderr,"event=peer_activate_rejected reason=no_frame\n");fflush(stderr);return FALSE;}
 UINT32 requested_width=freerdp_settings_get_uint32(peer->context->settings,FreeRDP_DesktopWidth);
 UINT32 requested_height=freerdp_settings_get_uint32(peer->context->settings,FreeRDP_DesktopHeight);
 UINT32 width=0,height=0;const char *policy="client";
 if (!peer_negotiate_size(requested_width,requested_height,&width,&height,&policy)) {
  fprintf(stderr,"event=peer_activate_rejected reason=invalid_size width=%u height=%u\n",requested_width,requested_height);fflush(stderr);return FALSE;
 }
 if (width!=requested_width || height!=requested_height) {
  /* Defensive: peer_capabilities normally published the negotiated size in the
   * Demand Active already. Keep the worker consistent if it did not. */
  if (!freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopWidth,width) ||
      !freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopHeight,height)) return FALSE;
 }
 ctx->width=width;ctx->height=height;
  /* Every activation (initial or after a client-driven Reactivate) must repaint
   * the whole client even when the source screen is static. */
  ctx->force_full_frame=TRUE;
  ctx->drawn=FALSE;
  ctx->layout_logged=FALSE;
  const char *peer_no_header=getenv("RDP_TEST_PEER_NO_BITMAP_HEADER");
  if (peer_no_header && strcmp(peer_no_header,"1")==0)
   freerdp_settings_set_bool(peer->context->settings,FreeRDP_NoBitmapCompressionHeader,TRUE);
   fprintf(stderr,"event=rdp_capabilities peer_no_bitmap_compression_header=%u\n",
    freerdp_settings_get_bool(peer->context->settings,FreeRDP_NoBitmapCompressionHeader));
   fflush(stderr);
   const char *raw_setting=getenv("RDP_TEST_RAW_BITMAP");
   if (raw_setting && strcmp(raw_setting,"1")==0 &&
       !freerdp_settings_set_bool(peer->context->settings,FreeRDP_NoBitmapCompressionHeader,FALSE))
    return FALSE;
   fprintf(stderr,"event=peer_codecs nscodec=%u\n",
    freerdp_settings_get_bool(peer->context->settings,FreeRDP_NSCodec));
   fflush(stderr);
  fprintf(stderr,"event=rdp_desktop_size width=%u height=%u\n",ctx->width,ctx->height);fflush(stderr);
 pthread_mutex_lock(&job->options->mutex);
 job->deadline=UINT64_MAX;
 job->options->requested_width=ctx->width;job->options->requested_height=ctx->height;
  pthread_mutex_unlock(&job->options->mutex);
  ctx->ready=TRUE;
  BYTE capture_size[8]={(BYTE)(ctx->width>>24),(BYTE)(ctx->width>>16),(BYTE)(ctx->width>>8),(BYTE)ctx->width,
                        (BYTE)(ctx->height>>24),(BYTE)(ctx->height>>16),(BYTE)(ctx->height>>8),(BYTE)ctx->height};
   if (send_agent_message(job->options,9,capture_size,sizeof(capture_size))) {
   fprintf(stderr,"event=agent_capture_size_requested width=%u height=%u\n",ctx->width,ctx->height);
   fflush(stderr);
   }
   fprintf(stderr,"event=peer_activate_complete width=%u height=%u\n",ctx->width,ctx->height);fflush(stderr);
   return TRUE;
}
/* ---- File clipboard (Issue 3) -------------------------------------------
 * Binding contract: docs/DESIGN-2026-11-08-clipboard-files.md.
 *
 * Remote -> local (direction 1): the client CB_FORMAT_LIST advertises
 * FileGroupDescriptorW; we request the packed descriptor list, validate it with
 * clipboard_files.h, open an Agent IPC offer (13 begin, 16 entries) and then
 * request the bytes file-by-file with CB_FILECONTENTS_REQUEST / RANGE chunks of
 * at most 65524 bytes, forwarding each CB_FILECONTENTS_RESPONSE as an IPC 14
 * chunk. The worker never writes temp files; the Agent does.
 *
 * Local -> remote (direction 2): the Agent sends 13 begin / 16 entries (absolute
 * paths) / 15 end; the worker validates each path (absolute, regular, not a
 * symlink, readable, size match), caches the serialized descriptor list and
 * advertises 0xC003+0xC004. Client CB_FORMAT_DATA_REQUEST(0xC003) is answered
 * from the cache; CB_FILECONTENTS_REQUEST serves FILECONTENTS_SIZE (8-byte LE
 * size) and FILECONTENTS_RANGE (pread in <=64 KiB blocks, range re-validated
 * against the advertised size and the real file).
 *
 * All cliprdr callbacks return CHANNEL_RC_OK on recoverable errors: a bad
 * clipboard must never kill the channel thread / RDP session. */

/* Last clipboard kind advertised to one RDP client (per peer, guarded by
 * options->clipboard_mutex). */
enum {
 CLIPBOARD_ADVERTISE_NONE=0,
 CLIPBOARD_ADVERTISE_TEXT=1,
 CLIPBOARD_ADVERTISE_FILES=2,
 CLIPBOARD_ADVERTISE_EMPTY=3
};

static void clipboard_local_files_free(rdp_clipboard_local_file *files,UINT32 count) {
 if(!files) return;
 for(UINT32 i=0;i<count;i++) {free(files[i].name);free(files[i].path);}
 free(files);
}

/* Guarded by options->clipboard_mutex. */
static void clipboard_clear_local_files_locked(server_options *options) {
 clipboard_local_files_free(options->local_files,options->local_file_count);
 options->local_files=NULL;options->local_file_count=0;options->local_file_total_bytes=0;
 free(options->local_descriptors);options->local_descriptors=NULL;options->local_descriptors_length=0;
}

/* Guarded by options->clipboard_mutex. Drops an Agent direction-2 offer that
 * has not been published yet. */
static void clipboard_offer_clear_locked(server_options *options) {
 clipboard_local_files_free(options->local_offer_files,options->local_offer_expected);
 options->local_offer_files=NULL;
 options->local_offer_active=FALSE;
 options->local_offer_expected=0;options->local_offer_received=0;
 options->local_offer_bytes=0;options->local_offer_error=RDP_CLIPBOARD_OK;
}

/* Guarded by options->clipboard_mutex. */
static UINT32 clipboard_local_kind_locked(server_options *options) {
 if(options->local_files && options->local_file_count>0) return CLIPBOARD_ADVERTISE_FILES;
 if(options->clipboard_utf8_length>0) return CLIPBOARD_ADVERTISE_TEXT;
 return CLIPBOARD_ADVERTISE_EMPTY;
}

/* Send one CB_FORMAT_LIST describing what the local clipboard offers. An empty
 * list revokes a previous file/text advertisement. */
static BOOL cliprdr_advertise(CliprdrServerContext *cliprdr,UINT32 kind) {
 CLIPRDR_FORMAT formats[2]={{0}};
 CLIPRDR_FORMAT_LIST list={0};
 list.common.msgType=CB_FORMAT_LIST;
 if(kind==CLIPBOARD_ADVERTISE_TEXT) {
  formats[0].formatId=RDP_CLIPBOARD_FORMAT_ID_TEXT;
  list.numFormats=1;list.formats=formats;
 } else if(kind==CLIPBOARD_ADVERTISE_FILES) {
  /* Keep the standard ids but also send the registered long names: real Windows
   * clients map the file formats by name (field evidence 2026-11-08). FreeRDP's
   * cliprdr_packet_format_list_new writes the names only while the negotiated
   * useLongFormatNames flag is set; cliprdr_client_capabilities logs it. */
  formats[0].formatId=RDP_CLIPBOARD_FORMAT_ID_FILE_GROUP_DESCRIPTOR;
  formats[0].formatName=(char *)RDP_CLIPBOARD_FORMAT_NAME_FILE_GROUP_DESCRIPTOR;
  formats[1].formatId=RDP_CLIPBOARD_FORMAT_ID_FILE_CONTENTS;
  formats[1].formatName=(char *)RDP_CLIPBOARD_FORMAT_NAME_FILE_CONTENTS;
  list.numFormats=2;list.formats=formats;
 } else {
  list.numFormats=0;list.formats=NULL;
 }
 if(!cliprdr || !cliprdr->ServerFormatList) return FALSE;
 UINT rc=cliprdr->ServerFormatList(cliprdr,&list);
 if(rc!=CHANNEL_RC_OK) {
  fprintf(stderr,"event=clipboard_advertise_failed kind=%u result=%u\n",kind,rc);fflush(stderr);
  return FALSE;
 }
 if(kind==CLIPBOARD_ADVERTISE_FILES) {
  fprintf(stderr,"event=clipboard_file_advertised formats=2 long_names=%u\n",
          cliprdr->useLongFormatNames ? 1u : 0u);
  fflush(stderr);
 } else {
  fprintf(stderr,"event=clipboard_local_advertised kind=%u\n",kind);
  fflush(stderr);
 }
 return TRUE;
}

/* Broadcast a local clipboard change to every active RDP peer (Agent IPC
 * thread). A peer whose advertised kind is unchanged gets no new PDU, so one
 * clipboard change sends exactly one CB_FORMAT_LIST per peer. */
static void clipboard_publish_local(server_options *options) {
 if(!options) return;
 UINT32 kind=CLIPBOARD_ADVERTISE_EMPTY;
 pthread_mutex_lock(&options->clipboard_mutex);
 kind=clipboard_local_kind_locked(options);
 pthread_mutex_unlock(&options->clipboard_mutex);
 pthread_mutex_lock(&options->mutex);
 for(unsigned i=0;i<MAX_PEERS;i++) {
  peer_job *job=options->jobs[i];
  peer_context *ctx=job && job->peer ? (peer_context *)job->peer->context : NULL;
  if(!ctx || !ctx->leased || !ctx->cliprdr || !ctx->cliprdr_initialized) continue;
  /* Field 2026-11-08: macOS->Windows text paste failed after a second text
   * copy. CB_FORMAT_LIST was only sent when the advertised kind changed
   * (text->text kept the same kind), so the real Windows client never learned
   * the local clipboard had changed and did not paste. MS-RDPECLIP requires the
   * owner to send CB_FORMAT_LIST on every clipboard change, so always advertise
   * (an empty list still revokes a previous ownership). */
  if(cliprdr_advertise(ctx->cliprdr,kind)) {
   pthread_mutex_lock(&options->clipboard_mutex);
   ctx->cliprdr_advertised_kind=kind;
   pthread_mutex_unlock(&options->clipboard_mutex);
  }
 }
 pthread_mutex_unlock(&options->mutex);
}

/* Queue the server-side clipboard initialization sequence: CB_CLIP_CAPS with our
 * general capability flags, then CB_MONITOR_READY (same content FreeRDP's
 * autoInitializationSequence would send, but from the caller's thread so the
 * following CB_FORMAT_LIST can never overtake it). */
static BOOL cliprdr_send_initialization(peer_context *ctx) {
 CliprdrServerContext *cliprdr=ctx ? ctx->cliprdr : NULL;
 if(!cliprdr || !cliprdr->ServerCapabilities || !cliprdr->MonitorReady) return FALSE;
 UINT32 general_flags=0;
 if(cliprdr->useLongFormatNames) general_flags|=CB_USE_LONG_FORMAT_NAMES;
 if(cliprdr->streamFileClipEnabled) general_flags|=CB_STREAM_FILECLIP_ENABLED;
 if(cliprdr->fileClipNoFilePaths) general_flags|=CB_FILECLIP_NO_FILE_PATHS;
 if(cliprdr->canLockClipData) general_flags|=CB_CAN_LOCK_CLIPDATA;
 if(cliprdr->hasHugeFileSupport) general_flags|=CB_HUGE_FILE_SUPPORT_ENABLED;
 CLIPRDR_GENERAL_CAPABILITY_SET general={0};
 general.capabilitySetType=CB_CAPSTYPE_GENERAL;
 general.capabilitySetLength=CB_CAPSTYPE_GENERAL_LEN;
 general.version=CB_CAPS_VERSION_2;
 general.generalFlags=general_flags;
 CLIPRDR_CAPABILITIES capabilities={0};
 capabilities.common.msgType=CB_CLIP_CAPS;
 capabilities.common.dataLen=4+CB_CAPSTYPE_GENERAL_LEN;
 capabilities.cCapabilitiesSets=1;
 capabilities.capabilitySets=(CLIPRDR_CAPABILITY_SET *)&general;
 UINT rc=cliprdr->ServerCapabilities(cliprdr,&capabilities);
 if(rc!=CHANNEL_RC_OK) {
  fprintf(stderr,"event=cliprdr_capabilities_failed result=%u\n",rc);fflush(stderr);
  return FALSE;
 }
 CLIPRDR_MONITOR_READY monitor={0};
 monitor.common.msgType=CB_MONITOR_READY;
 rc=cliprdr->MonitorReady(cliprdr,&monitor);
 if(rc!=CHANNEL_RC_OK) {
  fprintf(stderr,"event=cliprdr_monitor_ready_failed result=%u\n",rc);fflush(stderr);
  return FALSE;
 }
 fprintf(stderr,"event=cliprdr_initialized general_flags=0x%08x\n",general_flags);
 fflush(stderr);
 return TRUE;
}

/* Advertise the current local clipboard to one freshly connected peer (peer
 * thread, after cliprdr_send_initialization() queued the initialization
 * sequence). */
static void clipboard_publish_peer(peer_context *ctx) {
 if(!ctx || !ctx->cliprdr || !ctx->cliprdr_initialized || !ctx->context.peer ||
    !ctx->context.peer->ContextExtra) return;
 peer_job *job=ctx->context.peer->ContextExtra;
 UINT32 kind=CLIPBOARD_ADVERTISE_EMPTY;
 pthread_mutex_lock(&job->options->clipboard_mutex);
 kind=clipboard_local_kind_locked(job->options);
 const BOOL changed=ctx->cliprdr_advertised_kind!=kind;
 pthread_mutex_unlock(&job->options->clipboard_mutex);
 /* Do not send an empty format list during the connection handshake: there is
  * nothing to revoke for a fresh peer and some clients dislike clipboard PDUs
  * before their own initialization sequence completes. */
 if(changed && kind!=CLIPBOARD_ADVERTISE_EMPTY && cliprdr_advertise(ctx->cliprdr,kind)) {
  pthread_mutex_lock(&job->options->clipboard_mutex);
  ctx->cliprdr_advertised_kind=kind;
  pthread_mutex_unlock(&job->options->clipboard_mutex);
 }
}

/* Copy one local file entry (direction 2) for serving; false when the index is
 * not part of the currently advertised file list. */
static BOOL clipboard_local_file_lookup(server_options *options,UINT32 index,
                                        char *name,size_t name_size,UINT32 *name_length,
                                        char *path,size_t path_size,UINT64 *size) {
 BOOL found=FALSE;
 if(!options || !name || !path || !size) return FALSE;
 pthread_mutex_lock(&options->clipboard_mutex);
 if(index<options->local_file_count && options->local_files) {
  const rdp_clipboard_local_file *file=&options->local_files[index];
  if(file->path && file->name && file->path_length+1<=path_size &&
     file->name_length+1<=name_size) {
   memcpy(name,file->name,file->name_length);name[file->name_length]='\0';
   memcpy(path,file->path,file->path_length);path[file->path_length]='\0';
   if(name_length) *name_length=file->name_length;
   *size=file->size;
   found=TRUE;
  }
 }
 pthread_mutex_unlock(&options->clipboard_mutex);
 return found;
}

/* Validate an Agent-provided local file (contract section 5): absolute safe
 * path, regular file (never a symlink), readable, advertised size matches the
 * real stat size. Opens O_NOFOLLOW so a symlink swapped in after the lstat-like
 * check cannot redirect the read. *error_out receives the failing open/fstat
 * errno (0 on success) so the rejection log can identify a macOS TCC EPERM
 * without ever logging the path. */
static rdp_clipboard_status clipboard_validate_local_file(const char *name,UINT32 name_length,
                                                          const char *path,UINT32 path_length,
                                                          UINT64 size,int *error_out) {
 char copy[RDP_CLIPBOARD_MAX_PATH_BYTES+1];
 rdp_clipboard_status status=rdp_clipboard_validate_local_entry(name,name_length,path,path_length,size);
 if(error_out) *error_out=0;
 if(status!=RDP_CLIPBOARD_OK) return status;
 memcpy(copy,path,path_length);copy[path_length]='\0';
 int fd=open(copy,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0) {
  const int open_error=errno;
  if(error_out) *error_out=open_error;
  return (open_error==ELOOP || open_error==EMLINK) ? RDP_CLIPBOARD_ERR_NOT_REGULAR
                                                   : RDP_CLIPBOARD_ERR_UNREADABLE;
 }
 status=RDP_CLIPBOARD_ERR_UNREADABLE;
 struct stat info;
 if(fstat(fd,&info)==0) {
  if(!S_ISREG(info.st_mode)) status=RDP_CLIPBOARD_ERR_NOT_REGULAR;
  else if((UINT64)info.st_size!=size) status=RDP_CLIPBOARD_ERR_SIZE_MISMATCH;
  else status=RDP_CLIPBOARD_OK;
 } else if(error_out) {
  *error_out=errno;
 }
 close(fd);
 return status;
}

/* Read one FILECONTENTS_RANGE response payload: pread in <=64 KiB blocks, never
 * past the advertised size, re-checking the real file before reading. Returns a
 * malloc-owned buffer or NULL with *status set. *error_out receives the failing
 * open/fstat/pread errno (0 on success) for the unreadable rejection log (macOS
 * TCC EPERM diagnosis); no path is ever logged. No lock is held here. */
static BYTE *clipboard_read_file_range(const char *path,UINT64 advertised_size,UINT64 offset,
                                       UINT32 length,rdp_clipboard_status *status,
                                       int *error_out) {
 int fd=-1;
 BYTE *buffer=NULL;
 UINT32 done=0;
 BOOL ok=TRUE;
 if(status) *status=RDP_CLIPBOARD_ERR_UNREADABLE;
 if(error_out) *error_out=0;
 fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0) {
  if(error_out) *error_out=errno;
  if(status && (errno==ELOOP || errno==EMLINK)) *status=RDP_CLIPBOARD_ERR_NOT_REGULAR;
  return NULL;
 }
 struct stat info;
 if(fstat(fd,&info)<0) {if(error_out) *error_out=errno;close(fd);return NULL;}
 if(!S_ISREG(info.st_mode)) {close(fd);if(status) *status=RDP_CLIPBOARD_ERR_NOT_REGULAR;return NULL;}
 if((UINT64)info.st_size!=advertised_size) {close(fd);if(status) *status=RDP_CLIPBOARD_ERR_SIZE_MISMATCH;return NULL;}
 if(offset>advertised_size || (UINT64)length>advertised_size-offset) {
  close(fd);if(status) *status=RDP_CLIPBOARD_ERR_BAD_RANGE;return NULL;
 }
 buffer=malloc(length ? length : 1);
 if(!buffer) {if(error_out) *error_out=ENOMEM;close(fd);return NULL;}
 while(done<length) {
  size_t block=length-done;
  if(block>65536u) block=65536u;
  ssize_t received=pread(fd,buffer+done,block,(off_t)(offset+done));
  if(received<0) {
   if(errno==EINTR) continue;
   if(error_out) *error_out=errno;
   ok=FALSE;break;
  }
  if(received==0) {if(status) *status=RDP_CLIPBOARD_ERR_SIZE_MISMATCH;ok=FALSE;break;}
  done+=(UINT32)received;
 }
 close(fd);
 if(!ok) {free(buffer);return NULL;}
 if(status) *status=RDP_CLIPBOARD_OK;
 return buffer;
}

/* ---- Direction 1: remote -> local streaming (cliprdr thread only) -------- */

static server_options *cliprdr_peer_options(peer_context *ctx) {
 peer_job *job=ctx && ctx->context.peer ? ctx->context.peer->ContextExtra : NULL;
 return job ? job->options : NULL;
}

static void cliprdr_stream_reset(peer_context *ctx) {
 free(ctx->clip_file_stream_files);
 ctx->clip_file_stream_files=NULL;
 ctx->clip_file_stream_count=0;
 ctx->clip_file_stream_active=FALSE;
 ctx->clip_file_stream_id=0;
 ctx->clip_file_requested=0;
 ctx->clip_file_cancel_requested=FALSE;
 rdp_clipboard_chunk_reset(&ctx->clip_chunk);
}

/* Send the terminal IPC 15 for a direction-1 offer and reset the stream state.
 * `rejected` selects the grep-able log line: a failure logs
 * event=clipboard_file_rejected reason=..., completion/cancellation logs
 * event=clipboard_file_complete result=0|1. */
static void cliprdr_stream_end(peer_context *ctx,UINT8 status,rdp_clipboard_status reason,
                               BOOL rejected) {
 server_options *options=cliprdr_peer_options(ctx);
 UINT32 file_count=ctx->clip_file_stream_count;
 UINT64 bytes=ctx->clip_chunk.total_bytes;
 if(options) {
  (void)send_agent_clipboard_file_end(options,RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL,
                                      status,0,file_count);
 }
 if(rejected) {
  fprintf(stderr,"event=clipboard_file_rejected direction=remote_to_local reason=%s\n",
          rdp_clipboard_status_reason(reason));
 } else {
  fprintf(stderr,"event=clipboard_file_complete direction=remote_to_local files=%u bytes=%llu result=%u\n",
          file_count,(unsigned long long)bytes,status==RDP_CLIPBOARD_OFFER_STATUS_COMPLETE ? 0u : 1u);
 }
 fflush(stderr);
 cliprdr_stream_reset(ctx);
}

static void cliprdr_stream_complete(peer_context *ctx) {
 cliprdr_stream_end(ctx,RDP_CLIPBOARD_OFFER_STATUS_COMPLETE,RDP_CLIPBOARD_OK,FALSE);
}

static void cliprdr_stream_abort(peer_context *ctx,rdp_clipboard_status reason) {
 if(!ctx->clip_file_stream_active) return;
 cliprdr_stream_end(ctx,RDP_CLIPBOARD_OFFER_STATUS_ERROR,reason,TRUE);
}

static void cliprdr_stream_cancel(peer_context *ctx) {
 if(!ctx->clip_file_stream_active) return;
 cliprdr_stream_end(ctx,RDP_CLIPBOARD_OFFER_STATUS_CANCELLED,RDP_CLIPBOARD_OK,FALSE);
}

/* Request the next bounded RANGE chunk of the current file (or advance to the
 * next file / complete the offer when the current file is fully delivered). */
static void cliprdr_stream_request_next(peer_context *ctx) {
 server_options *options=cliprdr_peer_options(ctx);
 CliprdrServerContext *cliprdr=ctx->cliprdr;
 if(!options || !cliprdr || !cliprdr->ServerFileContentsRequest) {
  cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_CLIENT);
  return;
 }
 while(rdp_clipboard_chunk_file_complete(&ctx->clip_chunk)) {
  if(rdp_clipboard_chunk_complete(&ctx->clip_chunk)) {
   cliprdr_stream_complete(ctx);
   return;
  }
  const UINT32 next=ctx->clip_chunk.file_index+1;
  if(rdp_clipboard_chunk_start_file(&ctx->clip_chunk,next,
                                    ctx->clip_file_stream_files[next].size)!=RDP_CLIPBOARD_OK) {
   cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_STATE);
   return;
  }
 }
 UINT64 offset=0;
 const UINT32 length=rdp_clipboard_chunk_next_request(&ctx->clip_chunk,RDP_CLIPBOARD_CHUNK_BYTES,&offset);
 if(!length) {cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_STATE);return;}
 CLIPRDR_FILE_CONTENTS_REQUEST request={0};
 request.common.msgType=CB_FILECONTENTS_REQUEST;
 request.streamId=ctx->clip_file_stream_id;
 request.listIndex=ctx->clip_chunk.file_index;
 request.dwFlags=FILECONTENTS_RANGE;
 request.nPositionLow=(UINT32)(offset & 0xFFFFFFFFull);
 request.nPositionHigh=(UINT32)(offset >> 32);
 request.cbRequested=length;
 ctx->clip_file_requested=length;
 ctx->clip_file_last_activity=GetTickCount64();
 const UINT rc=cliprdr->ServerFileContentsRequest(cliprdr,&request);
 if(rc!=CHANNEL_RC_OK) {
  cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_CLIENT);
  return;
 }
 fprintf(stderr,"event=clipboard_file_request direction=remote_to_local index=%u offset=%llu length=%u\n",
         ctx->clip_chunk.file_index,(unsigned long long)offset,length);
 fflush(stderr);
}

/* Parse the client's FileGroupDescriptorW response and start a direction-1
 * offer: validate -> IPC begin + entries -> first content request. */
static void cliprdr_stream_start(peer_context *ctx,const BYTE *data,UINT32 data_length) {
 server_options *options=cliprdr_peer_options(ctx);
 rdp_clipboard_descriptor files[RDP_CLIPBOARD_MAX_FILES];
 rdp_clipboard_descriptor *copy=NULL;
 UINT32 count=0;
 UINT64 total=0;
 if(!options || !ctx->cliprdr) return;
 const rdp_clipboard_status status=rdp_clipboard_parse_file_list(data,data_length,files,
                                                                RDP_CLIPBOARD_MAX_FILES,&count);
 if(status!=RDP_CLIPBOARD_OK) {
  fprintf(stderr,"event=clipboard_file_rejected direction=remote_to_local reason=%s\n",
          rdp_clipboard_status_reason(status));
  fflush(stderr);
  return;
 }
 for(UINT32 i=0;i<count;i++) total+=files[i].size;
 if(!send_agent_clipboard_file_offer_begin(options,RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL,
                                           (UINT16)count,total)) {
  (void)send_agent_clipboard_file_end(options,RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL,
                                      RDP_CLIPBOARD_OFFER_STATUS_ERROR,0,(UINT32)count);
  fprintf(stderr,"event=clipboard_file_rejected direction=remote_to_local reason=ipc_failed\n");
  fflush(stderr);
  return;
 }
 for(UINT32 i=0;i<count;i++) {
  rdp_clipboard_entry entry={0};
  entry.direction=RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL;
  entry.file_index=i;
  entry.size=files[i].size;
  entry.name=files[i].name;
  entry.name_length=files[i].name_length;
  entry.path=NULL;
  entry.path_length=0;
  if(!send_agent_clipboard_file_entry(options,&entry)) {
   (void)send_agent_clipboard_file_end(options,RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL,
                                       RDP_CLIPBOARD_OFFER_STATUS_ERROR,0,(UINT32)count);
   fprintf(stderr,"event=clipboard_file_rejected direction=remote_to_local reason=ipc_failed\n");
   fflush(stderr);
   return;
  }
 }
 copy=malloc((size_t)count*sizeof(*copy));
 if(!copy) {
  (void)send_agent_clipboard_file_end(options,RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL,
                                      RDP_CLIPBOARD_OFFER_STATUS_ERROR,0,(UINT32)count);
  fprintf(stderr,"event=clipboard_file_rejected direction=remote_to_local reason=ipc_failed\n");
  fflush(stderr);
  return;
 }
 memcpy(copy,files,(size_t)count*sizeof(*copy));
 ctx->clip_file_stream_files=copy;
 ctx->clip_file_stream_count=count;
 ctx->clip_file_stream_id=1;
 ctx->clip_file_stream_active=TRUE;
 ctx->clip_file_cancel_requested=FALSE;
 ctx->clip_file_requested=0;
 if(rdp_clipboard_chunk_begin(&ctx->clip_chunk,count)!=RDP_CLIPBOARD_OK ||
    rdp_clipboard_chunk_start_file(&ctx->clip_chunk,0,files[0].size)!=RDP_CLIPBOARD_OK) {
  cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_STATE);
  return;
 }
 fprintf(stderr,"event=clipboard_file_offer direction=remote_to_local count=%u bytes=%llu\n",
         count,(unsigned long long)total);
 for(UINT32 i=0;i<count;i++) {
  fprintf(stderr,"event=clipboard_file_entry direction=remote_to_local index=%u size=%llu name_len=%u\n",
          i,(unsigned long long)files[i].size,files[i].name_length);
 }
 fflush(stderr);
 cliprdr_stream_request_next(ctx);
}

/* Handle one CB_FILECONTENTS_RESPONSE of the direction-1 offer: forward the
 * bytes to the Agent as IPC type 14, then ask for the next chunk. A short,
 * oversized or failed response aborts the offer without killing the session. */
static void cliprdr_stream_response(peer_context *ctx,
                                    const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
 server_options *options=cliprdr_peer_options(ctx);
 if(!ctx->clip_file_stream_active) return;
 if(ctx->clip_file_cancel_requested) {
  cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_CLIENT);
  return;
 }
 if(!response || !(response->common.msgFlags & CB_RESPONSE_OK) ||
    !response->requestedData || response->cbRequested==0 ||
    response->streamId!=ctx->clip_file_stream_id ||
    response->cbRequested!=ctx->clip_file_requested) {
  cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_CLIENT);
  return;
 }
 const UINT32 file_index=ctx->clip_chunk.file_index;
 const UINT64 offset=ctx->clip_chunk.offset;
 if(!options || !send_agent_clipboard_file_chunk(options,file_index,offset,
                                                 response->requestedData,
                                                 response->cbRequested)) {
  cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_IPC);
  return;
 }
 if(rdp_clipboard_chunk_accept(&ctx->clip_chunk,file_index,offset,
                               response->cbRequested)!=RDP_CLIPBOARD_OK) {
  cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_BAD_RANGE);
  return;
 }
 ctx->clip_file_requested=0;
 cliprdr_stream_request_next(ctx);
}

/* ---- direction 2: local -> remote serving (cliprdr thread) --------------- */

static void cliprdr_send_file_contents_fail(CliprdrServerContext *cliprdr,UINT32 stream_id) {
 CLIPRDR_FILE_CONTENTS_RESPONSE response={0};
 if(!cliprdr || !cliprdr->ServerFileContentsResponse) return;
 response.common.msgType=CB_FILECONTENTS_RESPONSE;
 response.common.msgFlags=CB_RESPONSE_FAIL;
 response.streamId=stream_id;
 response.cbRequested=0;
 response.requestedData=NULL;
 (void)cliprdr->ServerFileContentsResponse(cliprdr,&response);
}

static void cliprdr_log_rejected(const char *direction,rdp_clipboard_status status) {
 fprintf(stderr,"event=clipboard_file_rejected direction=%s reason=%s\n",direction,
         rdp_clipboard_status_reason(status));
 fflush(stderr);
}

/* Log a rejected local->remote file. For reason=unreadable it adds the
 * SANITIZED BASENAME (never the full path, never file content) and the
 * open/fstat/pread errno, so the field failure where macOS TCC blocks the
 * worker's open() of Desktop/Documents files (EPERM errno=1) is identifiable.
 * Other reasons keep the established single-line format. */
static void cliprdr_log_rejected_file(const char *direction,rdp_clipboard_status status,
                                      const char *name,UINT32 name_length,int error) {
 if(status==RDP_CLIPBOARD_ERR_UNREADABLE) {
  char safe[RDP_CLIPBOARD_MAX_NAME_BYTES+1];
  (void)rdp_clipboard_sanitize_name(name,name_length,safe,sizeof(safe));
  fprintf(stderr,
          "event=clipboard_file_rejected direction=%s reason=%s name=%s errno=%d\n",
          direction,rdp_clipboard_status_reason(status),safe,error);
  fflush(stderr);
  return;
 }
 cliprdr_log_rejected(direction,status);
}

/* Client CB_FORMAT_DATA_REQUEST: serve local text (format 13) or the cached
 * FileGroupDescriptorW list (0xC003). Anything else gets CB_RESPONSE_FAIL. */
static UINT cliprdr_server_format_data_request(CliprdrServerContext *cliprdr,
                                               const CLIPRDR_FORMAT_DATA_REQUEST *request) {
 if(!cliprdr || !request || !cliprdr->ServerFormatDataResponse) return CHANNEL_RC_OK;
 peer_context *ctx=(peer_context *)cliprdr->custom;
 if(!ctx || !ctx->context.peer || !ctx->context.peer->ContextExtra) return CHANNEL_RC_OK;
 server_options *options=((peer_job *)ctx->context.peer->ContextExtra)->options;
 if(request->requestedFormatId==RDP_CLIPBOARD_FORMAT_ID_TEXT) {
  UINT32 length=0;
  BYTE *utf8=NULL;
  pthread_mutex_lock(&options->clipboard_mutex);
  length=options->clipboard_utf8_length;
  if(length && length<=1024u*1024u) {
   utf8=malloc((size_t)length+1);
   if(utf8) {memcpy(utf8,options->clipboard_utf8,length);utf8[length]='\0';}
  }
  pthread_mutex_unlock(&options->clipboard_mutex);
  if(!utf8) return CHANNEL_RC_OK;
  size_t chars=0;
  WCHAR *wide=ConvertUtf8ToWCharAlloc((const char *)utf8,&chars);
  free(utf8);
  if(!wide) return CHANNEL_RC_OK;
  CLIPRDR_FORMAT_DATA_RESPONSE response={0};
  response.common.msgType=CB_FORMAT_DATA_RESPONSE;
  response.common.msgFlags=CB_RESPONSE_OK;
  response.common.dataLen=(UINT32)((chars+1)*sizeof(WCHAR));
  response.requestedFormatData=(const BYTE *)wide;
  const UINT rc=cliprdr->ServerFormatDataResponse(cliprdr,&response);
  fprintf(stderr,"event=clipboard_local_text_response result=%u\n",rc);fflush(stderr);
  free(wide);
  return CHANNEL_RC_OK;
 }
 if(request->requestedFormatId==RDP_CLIPBOARD_FORMAT_ID_FILE_GROUP_DESCRIPTOR) {
  BYTE *data=NULL;
  UINT32 length=0,file_count=0;
  pthread_mutex_lock(&options->clipboard_mutex);
  if(ctx->cliprdr_advertised_kind==CLIPBOARD_ADVERTISE_FILES &&
     options->local_descriptors && options->local_descriptors_length) {
   length=options->local_descriptors_length;
   file_count=options->local_file_count;
   data=malloc(length);
   if(data) memcpy(data,options->local_descriptors,length);
  }
  pthread_mutex_unlock(&options->clipboard_mutex);
  if(!data) {
   CLIPRDR_FORMAT_DATA_RESPONSE fail={0};
   fail.common.msgType=CB_FORMAT_DATA_RESPONSE;
   fail.common.msgFlags=CB_RESPONSE_FAIL;
   (void)cliprdr->ServerFormatDataResponse(cliprdr,&fail);
   cliprdr_log_rejected("local_to_remote",RDP_CLIPBOARD_ERR_BAD_RANGE);
   return CHANNEL_RC_OK;
  }
  CLIPRDR_FORMAT_DATA_RESPONSE response={0};
  response.common.msgType=CB_FORMAT_DATA_RESPONSE;
  response.common.msgFlags=CB_RESPONSE_OK;
  response.common.dataLen=length;
  response.requestedFormatData=data;
  const UINT rc=cliprdr->ServerFormatDataResponse(cliprdr,&response);
  fprintf(stderr,"event=clipboard_local_descriptor_response result=%u files=%u bytes=%u\n",
          rc,file_count,length);
  fflush(stderr);
  free(data);
  return CHANNEL_RC_OK;
 }
 {
  CLIPRDR_FORMAT_DATA_RESPONSE fail={0};
  fail.common.msgType=CB_FORMAT_DATA_RESPONSE;
  fail.common.msgFlags=CB_RESPONSE_FAIL;
  (void)cliprdr->ServerFormatDataResponse(cliprdr,&fail);
 }
 return CHANNEL_RC_OK;
}

/* Client CB_FILECONTENTS_REQUEST: serve FILECONTENTS_SIZE / FILECONTENTS_RANGE
 * from an Agent-provided local path. Every range is re-validated against the
 * advertised size and the real file before pread; any failure answers
 * CB_RESPONSE_FAIL with no data and logs a rejected reason. */
static UINT cliprdr_server_file_contents_request(CliprdrServerContext *cliprdr,
                                                 const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
 if(!cliprdr || !request || !cliprdr->ServerFileContentsResponse) return CHANNEL_RC_OK;
 peer_context *ctx=(peer_context *)cliprdr->custom;
 if(!ctx || !ctx->context.peer || !ctx->context.peer->ContextExtra) return CHANNEL_RC_OK;
 server_options *options=((peer_job *)ctx->context.peer->ContextExtra)->options;
 char name[RDP_CLIPBOARD_MAX_NAME_BYTES+1];
 char path[RDP_CLIPBOARD_MAX_PATH_BYTES+1];
 UINT32 name_length=0;
 UINT64 size=0;
 BYTE *data=NULL;
 UINT32 length=0;
 int read_error=0;
 BOOL advertised=FALSE;
 pthread_mutex_lock(&options->clipboard_mutex);
 advertised=ctx->cliprdr_advertised_kind==CLIPBOARD_ADVERTISE_FILES;
 pthread_mutex_unlock(&options->clipboard_mutex);
 if(!advertised ||
    !clipboard_local_file_lookup(options,request->listIndex,name,sizeof(name),&name_length,
                                 path,sizeof(path),&size)) {
  cliprdr_send_file_contents_fail(cliprdr,request->streamId);
  cliprdr_log_rejected("local_to_remote",RDP_CLIPBOARD_ERR_BAD_RANGE);
  return CHANNEL_RC_OK;
 }
 if(!rdp_clipboard_file_request_flags_valid(request->dwFlags)) {
  cliprdr_send_file_contents_fail(cliprdr,request->streamId);
  cliprdr_log_rejected("local_to_remote",RDP_CLIPBOARD_ERR_BAD_RANGE);
  return CHANNEL_RC_OK;
 }
 if(request->dwFlags & FILECONTENTS_SIZE) {
  UINT64 little=size;
  length=(UINT32)sizeof(UINT64);
  data=malloc(length);
  if(data) {
   for(UINT32 i=0;i<length;i++) data[i]=(BYTE)(little>>(8u*i));
  } else {
   cliprdr_send_file_contents_fail(cliprdr,request->streamId);
   cliprdr_log_rejected_file("local_to_remote",RDP_CLIPBOARD_ERR_UNREADABLE,name,name_length,
                             ENOMEM);
   return CHANNEL_RC_OK;
  }
  fprintf(stderr,"event=clipboard_file_request direction=local_to_remote index=%u offset=0 length=%u\n",
          request->listIndex,length);
  fflush(stderr);
 } else {
  /* FILECONTENTS_RANGE: clamp at EOF like a Windows server. Windows clients
   * (mstsc) request full 256 KiB chunks without clamping the last request and
   * expect a SHORT CB_FILECONTENTS_RESPONSE, not a failure (field bug: 1048087
   * byte file, request 262144 at offset 786432 -> previously bad_range). */
  const UINT64 offset=((UINT64)request->nPositionHigh<<32)|request->nPositionLow;
  const UINT32 requested=request->cbRequested;
  rdp_clipboard_status status=rdp_clipboard_clamp_range(size,offset,requested,
                                                        RDP_CLIPBOARD_MAX_RESPONSE_BYTES,&length);
  if(status==RDP_CLIPBOARD_OK) {
   data=clipboard_read_file_range(path,size,offset,length,&status,&read_error);
  }
  if(status!=RDP_CLIPBOARD_OK || !data) {
   cliprdr_send_file_contents_fail(cliprdr,request->streamId);
   cliprdr_log_rejected_file("local_to_remote",
                             status==RDP_CLIPBOARD_OK ? RDP_CLIPBOARD_ERR_UNREADABLE : status,
                             name,name_length,read_error);
   return CHANNEL_RC_OK;
  }
  if(length!=requested) {
   fprintf(stderr,"event=clipboard_file_request direction=local_to_remote index=%u offset=%llu length=%u requested=%u\n",
           request->listIndex,(unsigned long long)offset,length,requested);
  } else {
   fprintf(stderr,"event=clipboard_file_request direction=local_to_remote index=%u offset=%llu length=%u\n",
           request->listIndex,(unsigned long long)offset,length);
  }
  fflush(stderr);
 }
 CLIPRDR_FILE_CONTENTS_RESPONSE response={0};
 response.common.msgType=CB_FILECONTENTS_RESPONSE;
 response.common.msgFlags=CB_RESPONSE_OK;
 response.streamId=request->streamId;
 response.cbRequested=length;
 response.requestedData=data;
 (void)cliprdr->ServerFileContentsResponse(cliprdr,&response);
 free(data);
 return CHANNEL_RC_OK;
}

/* ---- Agent IPC handlers (Agent thread) ---------------------------------- */

static void clipboard_agent_offer_fail(server_options *options,rdp_clipboard_status status) {
 pthread_mutex_lock(&options->clipboard_mutex);
 if(options->local_offer_active && options->local_offer_error==RDP_CLIPBOARD_OK)
  options->local_offer_error=status;
 pthread_mutex_unlock(&options->clipboard_mutex);
}

/* IPC 13 direction 2: a new local clipboard file list starts. The previous
 * local advertisement is revoked immediately (empty CB_FORMAT_LIST) and the
 * previous list is dropped; entries are validated as they arrive. */
static void clipboard_agent_offer_begin(server_options *options,
                                        const rdp_clipboard_offer_begin *begin) {
 pthread_mutex_lock(&options->clipboard_mutex);
 clipboard_offer_clear_locked(options);
 clipboard_clear_local_files_locked(options);
 options->clipboard_utf8_length=0; /* a file clipboard replaces stale text */
 options->local_offer_files=calloc(begin->file_count,sizeof(rdp_clipboard_local_file));
 BOOL allocated=options->local_offer_files!=NULL;
 if(!allocated) {
  options->local_offer_error=RDP_CLIPBOARD_ERR_IPC;
 } else {
  options->local_offer_active=TRUE;
  options->local_offer_expected=begin->file_count;
  options->local_offer_received=0;
  options->local_offer_bytes=0;
  options->local_offer_error=RDP_CLIPBOARD_OK;
 }
 pthread_mutex_unlock(&options->clipboard_mutex);
 if(!allocated) cliprdr_log_rejected("local_to_remote",RDP_CLIPBOARD_ERR_IPC);
 clipboard_publish_local(options); /* revoke the superseded advertisement */
}

/* IPC 16 direction 2: one Agent file entry. Validates name/path/limits and the
 * real filesystem metadata before the list can be advertised. */
static void clipboard_agent_offer_entry(server_options *options,
                                        const rdp_clipboard_entry *entry) {
 rdp_clipboard_status status=RDP_CLIPBOARD_OK;
 char *name_copy=NULL;
 char *path_copy=NULL;
 int validation_error=0;
 const UINT32 index=entry->file_index;
 BOOL active=FALSE;
 pthread_mutex_lock(&options->clipboard_mutex);
 if(!options->local_offer_active || !options->local_offer_files) {
  active=FALSE;
 } else if(index>=options->local_offer_expected ||
           options->local_offer_files[index].path!=NULL) {
  status=RDP_CLIPBOARD_ERR_BAD_FORMAT;
  active=TRUE;
 } else {
  active=TRUE;
  status=clipboard_validate_local_file(entry->name,entry->name_length,
                                       entry->path,entry->path_length,entry->size,
                                       &validation_error);
  if(status==RDP_CLIPBOARD_OK) {
   name_copy=malloc((size_t)entry->name_length+1);
   path_copy=malloc((size_t)entry->path_length+1);
   if(name_copy && path_copy) {
    memcpy(name_copy,entry->name,entry->name_length);
    name_copy[entry->name_length]='\0';
    memcpy(path_copy,entry->path,entry->path_length);
    path_copy[entry->path_length]='\0';
    options->local_offer_files[index].name=name_copy;
    options->local_offer_files[index].name_length=entry->name_length;
    options->local_offer_files[index].path=path_copy;
    options->local_offer_files[index].path_length=entry->path_length;
    options->local_offer_files[index].size=entry->size;
    options->local_offer_received++;
    options->local_offer_bytes+=entry->size;
    name_copy=NULL;path_copy=NULL;
    if(options->local_offer_bytes>RDP_CLIPBOARD_MAX_TOTAL_BYTES)
     status=RDP_CLIPBOARD_ERR_TOO_LARGE;
   } else {
    status=RDP_CLIPBOARD_ERR_IPC;
   }
  }
 }
 if(status!=RDP_CLIPBOARD_OK && options->local_offer_error==RDP_CLIPBOARD_OK)
  options->local_offer_error=status;
 pthread_mutex_unlock(&options->clipboard_mutex);
 free(name_copy);free(path_copy);
 if(!active) return;
 if(status!=RDP_CLIPBOARD_OK) {
  cliprdr_log_rejected_file("local_to_remote",status,entry->name,entry->name_length,
                            validation_error);
  return;
 }
 fprintf(stderr,"event=clipboard_file_entry direction=local_to_remote index=%u size=%llu name_len=%u\n",
         entry->file_index,(unsigned long long)entry->size,entry->name_length);
 fflush(stderr);
}

/* IPC 15 direction 2: complete the offer. On success the validated file list
 * becomes the local clipboard and is advertised to the RDP client; on any error
 * it is dropped and the advertisement stays empty (revoked at begin). */
static void clipboard_agent_offer_end(server_options *options,
                                      const rdp_clipboard_offer_end *end) {
 rdp_clipboard_status status=RDP_CLIPBOARD_OK;
 rdp_clipboard_descriptor *array=NULL;
 BYTE *descriptors=NULL;
 UINT32 descriptors_length=0;
 UINT32 count=0;
 UINT64 bytes=0;
 BOOL cancelled=FALSE;
 pthread_mutex_lock(&options->clipboard_mutex);
 if(!options->local_offer_active) {
  pthread_mutex_unlock(&options->clipboard_mutex);
  fprintf(stderr,"event=agent_ipc_ignored type=%u\n",(unsigned)RDP_CLIPBOARD_IPC_TYPE_OFFER_END);
  fflush(stderr);
  return;
 }
 count=options->local_offer_expected;
 if(end->status==RDP_CLIPBOARD_OFFER_STATUS_CANCELLED) {
  cancelled=TRUE;
  status=RDP_CLIPBOARD_ERR_STATE;
 } else if(end->status!=RDP_CLIPBOARD_OFFER_STATUS_COMPLETE) {
  status=RDP_CLIPBOARD_ERR_IPC;
 } else if(end->file_count!=count || options->local_offer_received!=count) {
  status=options->local_offer_error!=RDP_CLIPBOARD_OK ? options->local_offer_error
                                                     : RDP_CLIPBOARD_ERR_BAD_FORMAT;
 } else if(options->local_offer_error!=RDP_CLIPBOARD_OK) {
  status=options->local_offer_error;
 } else {
  bytes=options->local_offer_bytes;
  array=calloc(count ? count : 1,sizeof(*array));
  if(!array) {
   status=RDP_CLIPBOARD_ERR_IPC;
  } else {
   for(UINT32 i=0;i<count;i++) {
    const rdp_clipboard_local_file *file=&options->local_offer_files[i];
    UINT32 name_length=file->name_length;
    if(name_length>RDP_CLIPBOARD_MAX_NAME_BYTES) name_length=RDP_CLIPBOARD_MAX_NAME_BYTES;
    memcpy(array[i].name,file->name,name_length);
    array[i].name[name_length]='\0';
    array[i].name_length=name_length;
    array[i].size=file->size;
    array[i].attributes=FILE_ATTRIBUTE_NORMAL;
   }
   status=rdp_clipboard_build_file_list(array,count,&descriptors,&descriptors_length);
  }
  if(status==RDP_CLIPBOARD_OK) {
   clipboard_local_files_free(options->local_files,options->local_file_count);
   options->local_files=options->local_offer_files;
   options->local_offer_files=NULL;
   options->local_file_count=count;
   options->local_file_total_bytes=bytes;
   free(options->local_descriptors);
   options->local_descriptors=descriptors;
   options->local_descriptors_length=descriptors_length;
   descriptors=NULL;
  }
 }
 clipboard_offer_clear_locked(options);
 pthread_mutex_unlock(&options->clipboard_mutex);
 free(array);
 free(descriptors);
 if(cancelled) {
  fprintf(stderr,"event=clipboard_file_complete direction=local_to_remote files=%u bytes=0 result=1\n",
          count);
  fflush(stderr);
  return;
 }
 if(status!=RDP_CLIPBOARD_OK) {
  cliprdr_log_rejected("local_to_remote",status);
  return;
 }
 fprintf(stderr,"event=clipboard_file_offer direction=local_to_remote count=%u bytes=%llu\n",
         count,(unsigned long long)bytes);
 fprintf(stderr,"event=clipboard_file_complete direction=local_to_remote files=%u bytes=%llu result=0\n",
         count,(unsigned long long)bytes);
 fflush(stderr);
 clipboard_publish_local(options);
}

/* Entry point for Agent IPC types 13..16 (Agent thread). Never closes the IPC
 * connection: malformed clipboard messages are logged and dropped. */
static void clipboard_agent_ipc_message(server_options *options,UINT16 message_type,
                                        const BYTE *payload,UINT32 payload_size) {
 if(!options) return;
 if(message_type==RDP_CLIPBOARD_IPC_TYPE_OFFER_BEGIN) {
  rdp_clipboard_offer_begin begin;
  if(!rdp_clipboard_parse_offer_begin(payload,payload_size,&begin)) {
   /* Keep the log reason within the contract vocabulary: on a well-formed
    * 16-byte payload the limits are what can make it invalid. */
   rdp_clipboard_status reason=RDP_CLIPBOARD_ERR_BAD_FORMAT;
   if(payload && payload_size==RDP_CLIPBOARD_IPC_BEGIN_BYTES) {
    const UINT16 file_count=rdp_clipboard_read_be16(payload+2);
    const UINT64 total_bytes=rdp_clipboard_read_be64(payload+4);
    if(file_count>RDP_CLIPBOARD_MAX_FILES) reason=RDP_CLIPBOARD_ERR_TOO_MANY_FILES;
    else if(total_bytes>RDP_CLIPBOARD_MAX_TOTAL_BYTES) reason=RDP_CLIPBOARD_ERR_TOO_LARGE;
   }
   cliprdr_log_rejected("local_to_remote",reason);
   return;
  }
  if(begin.direction!=RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE) {
   fprintf(stderr,"event=agent_ipc_ignored type=%u\n",(unsigned)message_type);fflush(stderr);
   return;
  }
  clipboard_agent_offer_begin(options,&begin);
 } else if(message_type==RDP_CLIPBOARD_IPC_TYPE_ENTRY) {
  rdp_clipboard_entry entry;
  if(!rdp_clipboard_parse_entry(payload,payload_size,&entry)) {
   rdp_clipboard_status status=RDP_CLIPBOARD_ERR_BAD_FORMAT;
   if(payload && payload_size>=RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES) {
    const UINT32 name_length=rdp_clipboard_read_be16(payload+2);
    const UINT32 path_length=rdp_clipboard_read_be16(payload+16);
    if(payload_size==rdp_clipboard_entry_wire_length(name_length,path_length))
     status=RDP_CLIPBOARD_ERR_BAD_NAME;
   }
   clipboard_agent_offer_fail(options,status);
   cliprdr_log_rejected("local_to_remote",status);
   return;
  }
  if(entry.direction!=RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE) {
   fprintf(stderr,"event=agent_ipc_ignored type=%u\n",(unsigned)message_type);fflush(stderr);
   return;
  }
  clipboard_agent_offer_entry(options,&entry);
 } else if(message_type==RDP_CLIPBOARD_IPC_TYPE_OFFER_END) {
  rdp_clipboard_offer_end end;
  if(!rdp_clipboard_parse_offer_end(payload,payload_size,&end)) {
   cliprdr_log_rejected("local_to_remote",RDP_CLIPBOARD_ERR_BAD_FORMAT);
   return;
  }
  if(end.direction!=RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE) {
   fprintf(stderr,"event=agent_ipc_ignored type=%u\n",(unsigned)message_type);fflush(stderr);
   return;
  }
  clipboard_agent_offer_end(options,&end);
 }
 /* IPC 14 is worker->agent only; ignore it from the Agent (forward compatible). */
}

/* ---- cliprdr callbacks --------------------------------------------------- */

/* Client CB_CLIP_CAPS: FreeRDP has already merged the client's general flags
 * into the server context when this callback runs (a capability we offered is
 * cleared when the client does not support it). Log the resulting flag set:
 * the file advertisement/format-list names depend on useLongFormatNames, and a
 * real-client regression (device mode, odd client) is visible here. */
static UINT cliprdr_client_capabilities(CliprdrServerContext *cliprdr,
                                        const CLIPRDR_CAPABILITIES *capabilities) {
 (void)capabilities;
 if(cliprdr) {
  fprintf(stderr,"event=cliprdr_client_capabilities long_names=%u stream_file_clip=%u huge_files=%u\n",
          cliprdr->useLongFormatNames ? 1u : 0u,
          cliprdr->streamFileClipEnabled ? 1u : 0u,
          cliprdr->hasHugeFileSupport ? 1u : 0u);
  fflush(stderr);
 }
 return CHANNEL_RC_OK;
}

/* Client CB_FORMAT_LIST: a new client clipboard. Any remote->local stream in
 * flight is superseded; a file offer is preferred over text (contract 4). The
 * selected semantic kind is stored (not the raw id) and the data request is
 * sent with the formatId the client advertised. */
static UINT cliprdr_client_formats(CliprdrServerContext *cliprdr,
                                   const CLIPRDR_FORMAT_LIST *formats) {
 peer_context *ctx=cliprdr ? (peer_context *)cliprdr->custom : NULL;
 const rdp_clipboard_format_selection selected=rdp_clipboard_select_format(formats);
 if(ctx) {
  if(ctx->clip_file_stream_active) cliprdr_stream_cancel(ctx);
  ctx->cliprdr_pending_kind=selected.kind;
 }
 /* Field diagnosis: the exact advertised id is what a real Windows client must
  * be asked for; a fixed-id request is answered with CB_RESPONSE_FAIL. */
 if(selected.kind!=RDP_CLIPBOARD_KIND_NONE && selected.format_id)
  fprintf(stderr,"event=clipboard_client_data_request id=%u kind=%s\n",
          (unsigned)selected.format_id,
          selected.kind==RDP_CLIPBOARD_KIND_FILES ? "files" : "text");
 const UINT rc=rdp_clipboard_client_formats_selected(cliprdr,formats,&selected);
 fprintf(stderr,"event=clipboard_client_formats result=%u selected=%u kind=%u formats=%u\n",
         rc,(unsigned)selected.format_id,(unsigned)selected.kind,
         formats ? formats->numFormats : 0);
 if(formats && formats->formats) {
  /* Field diagnosis: the Windows client's exact format list decides whether a
   * file copy is recognised. Log ids + long names (no clipboard content). */
  for(UINT32 i=0;i<formats->numFormats;i++) {
   const CLIPRDR_FORMAT *format=&formats->formats[i];
   fprintf(stderr,"event=clipboard_client_format index=%u id=%u name=%s\n",i,
           (unsigned)format->formatId,format->formatName ? format->formatName : "-");
  }
 }
 fflush(stderr);
 return CHANNEL_RC_OK;
}

/* Client CB_FORMAT_DATA_RESPONSE: either the remote->local file descriptor list
 * or text, dispatched by the semantic pending kind (the wire id can be a
 * client-advertised dynamic id, e.g. 49314/13). */
static UINT cliprdr_client_data_response(CliprdrServerContext *cliprdr,
                                         const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
 if(!cliprdr || !response) return CHANNEL_RC_OK;
 peer_context *ctx=(peer_context *)cliprdr->custom;
 if(!ctx) return CHANNEL_RC_OK;
 const UINT32 pending_kind=ctx->cliprdr_pending_kind;
 const BOOL ok=(response->common.msgFlags & CB_RESPONSE_OK) ? TRUE : FALSE;
 const BYTE *data=response->requestedFormatData;
 const UINT32 data_length=response->common.dataLen;
 const char *pending_name=pending_kind==RDP_CLIPBOARD_KIND_FILES ? "files" :
                          (pending_kind==RDP_CLIPBOARD_KIND_TEXT ? "text" : "none");
 ctx->cliprdr_pending_kind=RDP_CLIPBOARD_KIND_NONE;
 /* Field diagnosis: distinguish "client refused" (FAIL flag) from "client
  * returned no data" (OK with dataLen 0) and from our own parse rejection. */
 fprintf(stderr,"event=clipboard_client_data_response pending=%s ok=%u bytes=%u\n",
         pending_name,ok ? 1u : 0u,(unsigned)data_length);
 fflush(stderr);
 if(pending_kind==RDP_CLIPBOARD_KIND_FILES) {
  if(ctx->clip_file_stream_active) {
   cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_STATE);
  }
  if(!ok || !data || data_length==0) {
   cliprdr_log_rejected("remote_to_local",RDP_CLIPBOARD_ERR_CLIENT);
   return CHANNEL_RC_OK;
  }
  cliprdr_stream_start(ctx,data,data_length);
  return CHANNEL_RC_OK;
 }
 if(pending_kind==RDP_CLIPBOARD_KIND_TEXT) {
  peer_job *job=ctx->context.peer ? ctx->context.peer->ContextExtra : NULL;
  BOOL sent=FALSE;
  if(ok && data && job) sent=send_agent_clipboard_utf16(job->options,data,data_length);
  fprintf(stderr,"event=clipboard_client_text_forwarded result=%u\n",sent);
  fflush(stderr);
 }
 return CHANNEL_RC_OK;
}

/* Client CB_FILECONTENTS_RESPONSE: one chunk of a remote->local file. */
static UINT cliprdr_client_file_contents_response(
    CliprdrServerContext *cliprdr,const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
 if(!cliprdr || !response) return CHANNEL_RC_OK;
 peer_context *ctx=(peer_context *)cliprdr->custom;
 if(ctx) cliprdr_stream_response(ctx,response);
 return CHANNEL_RC_OK;
}

/* Per-peer teardown: abort an in-flight direction-1 offer so the Agent cleans
 * its temp directory. Called by the peer thread after the cliprdr channel
 * thread was stopped (no concurrency with the callbacks above). */
static void cliprdr_peer_cleanup_stream(peer_context *ctx) {
 if(ctx->clip_file_stream_active) cliprdr_stream_abort(ctx,RDP_CLIPBOARD_ERR_CLIENT);
}

static BOOL peer_post_connect(freerdp_peer *peer) {
 peer_context *ctx=(peer_context *)peer->context;
 fprintf(stderr,"event=peer_post_connect_started leased=%u\n",ctx->leased);fflush(stderr);
 if(!ctx->leased) {fprintf(stderr,"event=peer_post_connect_rejected reason=not_leased\n");fflush(stderr);return FALSE;}
 peer_job *job=peer->ContextExtra;
  if(job && !job->options->test_pattern && ctx->cliprdr) {
   UINT rc=ctx->cliprdr->Start(ctx->cliprdr);
    fprintf(stderr,"event=cliprdr_start result=%u\n",rc);fflush(stderr);
    if(rc==CHANNEL_RC_OK) {
     /* The FreeRDP channel thread is running but (autoInitializationSequence is
      * off) it sends nothing yet: queue CB_CLIP_CAPS + CB_MONITOR_READY from this
      * thread, then the current local clipboard as CB_FORMAT_LIST. A format list
      * that overtakes the initialization sequence corrupts a conforming client's
      * cliprdr channel (test_26 flake, 2026-11-08). */
     ctx->cliprdr_initialized=cliprdr_send_initialization(ctx);
     if(ctx->cliprdr_initialized) clipboard_publish_peer(ctx);
    }
   }
  fprintf(stderr,"event=peer_post_connect_complete clipboard=%u\n",ctx->cliprdr!=NULL);fflush(stderr);
  return TRUE;
}
static BOOL note_early_input(peer_context *ctx,const char *kind) {
 if (ctx && !ctx->early_input_logged) {
  ctx->early_input_logged=TRUE;
  fprintf(stderr,"event=early_input_dropped kind=%s reason=session_not_ready\n",kind);
  fflush(stderr);
 }
 return TRUE;
}
/* Opt-in per-event input trace (RDP_INPUT_TRACE=1), diagnostics only.
 *
 * The Worker is the only place that sees exactly what the RDP client sent, so a
 * lost modifier key-up has to be observed here: the Agent trace shows what was
 * forwarded, this one shows what arrived (and what was dropped during a
 * reactivation window). Default off; the one-line-per-kind audit log below is
 * unchanged.
 *
 * Privacy: keyboard events log the RDP scancode (a physical key location), never
 * text. Unicode events log flags ONLY - the code is typed text and must never be
 * written to a log, even with the trace enabled. */
static BOOL input_trace_enabled(void) {
 static int cached=-1;
 if (cached<0) {
  const char *value=getenv("RDP_INPUT_TRACE");
  cached=(value && value[0]=='1' && value[1]=='\0') ? 1 : 0;
 }
 return cached==1;
}
static void trace_key_event(const char *event,const char *kind,UINT16 flags,UINT8 code) {
 if (!input_trace_enabled()) return;
 fprintf(stderr,"event=%s kind=%s flags=0x%04x code=0x%02x\n",event,kind,(unsigned)flags,(unsigned)code);
 fflush(stderr);
}
static void trace_unicode_event(const char *event,UINT16 flags) {
 if (!input_trace_enabled()) return;
 /* No unicode code here: it is user-typed text. */
 fprintf(stderr,"event=%s kind=unicode flags=0x%04x\n",event,(unsigned)flags);
 fflush(stderr);
}
static BOOL keyboard(rdpInput *input, UINT16 flags, UINT8 code) {
 peer_context *ctx=(peer_context *)input->context;
 /* Early input is legal (clients send input during finalization / reactivation).
  * Returning FALSE here fails FreeRDP's receive path and drops the connection -
  * a fast reconnect used to die at CONNECTION_STATE_FINALIZATION_FONT_LIST with
  * "26 bytes not processed". Ignore input until the session is ready instead. */
 if (!ctx->leased || !ctx->ready) {
  trace_key_event("input_trace_dropped","key",flags,code);
  return note_early_input(ctx,"key");
 }
 peer_job *job=ctx->context.peer ? ctx->context.peer->ContextExtra : NULL;
 if(!job) return FALSE;
 if(!job->options->test_pattern && !send_key_event(ctx,flags,code,2)) {
  fprintf(stderr,"event=agent_input_dropped kind=key reason=agent_write_failed\n");fflush(stderr);
  trace_key_event("input_trace_dropped","key",flags,code);
 } else {
  trace_key_event("input_trace","key",flags,code);
 }
 ctx->inputs |= 1;
 return TRUE;
}
static BOOL unicode_keyboard(rdpInput *input, UINT16 flags, UINT16 code) {
 peer_context *ctx=(peer_context *)input->context;
 if(!ctx->leased || !ctx->ready) {
  trace_unicode_event("input_trace_dropped",flags);
  return note_early_input(ctx,"unicode"); /* early input: ignore, never fail */
 }
 peer_job *job=ctx->context.peer ? ctx->context.peer->ContextExtra : NULL;
 if(!job) return FALSE;
 if(!job->options->test_pattern && !send_key_event(ctx,flags,code,3)) {
  fprintf(stderr,"event=agent_input_dropped kind=unicode reason=agent_write_failed\n");fflush(stderr);
  trace_unicode_event("input_trace_dropped",flags);
 } else {
  trace_unicode_event("input_trace",flags);
 }
 ctx->inputs|=1;
 return TRUE;
}
static BOOL mouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
 peer_context *ctx=(peer_context *)input->context;
 if (!ctx->leased || !ctx->ready) return note_early_input(ctx,"mouse"); /* early input: ignore, never fail */
 peer_job *job=ctx->context.peer ? ctx->context.peer->ContextExtra : NULL;
 if(!job) return FALSE;
 if(!job->options->test_pattern && !send_mouse_event(ctx,flags,x,y)) {
  fprintf(stderr,"event=agent_input_dropped kind=mouse reason=agent_write_failed\n");fflush(stderr);
 }
 ctx->inputs |= 2;
 return TRUE;
}
static BOOL synchronize(rdpInput *input, UINT32 flags) {(void)input; (void)flags;return TRUE;}
static BOOL refresh(rdpContext *context, BYTE count, const RECTANGLE_16 *areas) {
 (void)count; (void)areas;
 peer_context *ctx=(peer_context *)context;
 ctx->force_full_frame=TRUE;
 if (ctx->output_suppressed) {
  fprintf(stderr,"event=refresh_deferred reason=output_suppressed\n");fflush(stderr);
  return TRUE;
 }
 return draw_pattern_with_deadline(context->peer);
}

#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
static UINT peer_gfx_caps_advertise(RdpgfxServerContext *gfx, const RDPGFX_CAPS_ADVERTISE_PDU *advertise) {
 peer_context *ctx=gfx ? (peer_context *)gfx->custom : NULL;
 RDPGFX_CAPSET selected={0};
 RDPGFX_CAPS_CONFIRM_PDU confirm={0};
 if (!ctx || ctx->rdpgfx!=gfx || !advertise) return ERROR_INVALID_DATA;
 if (!rdp_gfx_select_avc420(TRUE,ctx->avc_encoder!=NULL,advertise->capsSets,advertise->capsSetCount,&selected)) {
  (void)rdp_gfx_runtime_caps_confirmed(&ctx->gfx_runtime,FALSE);
  return ERROR_NOT_SUPPORTED;
 }
 confirm.capsSet=&selected;
 if (!gfx->CapsConfirm) {
  (void)rdp_gfx_runtime_caps_confirmed(&ctx->gfx_runtime,FALSE);
  return ERROR_INVALID_DATA;
 }
 UINT rc=gfx->CapsConfirm(gfx,&confirm);
 if (rc!=CHANNEL_RC_OK || !rdp_gfx_runtime_caps_confirmed(&ctx->gfx_runtime,rc==CHANNEL_RC_OK))
  return rc==CHANNEL_RC_OK ? ERROR_INVALID_DATA : rc;
 rdp_gfx_request_refresh(&ctx->gfx_flow);
 return CHANNEL_RC_OK;
}

static UINT peer_gfx_frame_acknowledge(RdpgfxServerContext *gfx, const RDPGFX_FRAME_ACKNOWLEDGE_PDU *ack) {
 peer_context *ctx=gfx ? (peer_context *)gfx->custom : NULL;
 uint64_t latency_ms=0;
 if (!ctx || ctx->rdpgfx!=gfx || !ack ||
     !rdp_gfx_ack_record(&ctx->gfx_flow,ack->frameId,ack->queueDepth,
                         GetTickCount64(),&ctx->gfx_ack_metrics,&latency_ms)) {
  if (ctx) ctx->gfx_runtime.phase=RDP_GFX_RUNTIME_FAILED;
  return ERROR_INVALID_DATA;
 }
 if (rdp_gfx_ack_metrics_should_report(&ctx->gfx_ack_metrics)) {
  fprintf(stderr,"event=gfx_ack_metrics frame_id=%u queue_depth=%u pending=%u samples=%llu last_latency_ms=%llu avg_latency_ms=%llu max_latency_ms=%llu\n",
   (unsigned)ack->frameId,(unsigned)ack->queueDepth,ctx->gfx_flow.pending,
   (unsigned long long)ctx->gfx_ack_metrics.samples,
   (unsigned long long)latency_ms,
   (unsigned long long)rdp_gfx_ack_average_latency_ms(&ctx->gfx_ack_metrics),
   (unsigned long long)ctx->gfx_ack_metrics.max_latency_ms);
  fflush(stderr);
 }
 return CHANNEL_RC_OK;
}

static BOOL peer_gfx_opted_in(void) {
 const char *value=getenv("RDP_ENABLE_AVC420");
 return value && strcmp(value,"1")==0;
}

static BOOL peer_gfx_initialize(freerdp_peer *peer, peer_context *ctx, rdpSettings *settings) {
 BOOL enabled=peer_gfx_opted_in();
 ctx->gfx_ack_metrics=(rdp_gfx_ack_metrics){0};
 rdp_gfx_runtime_init(&ctx->gfx_runtime,enabled,FALSE);
 if (!enabled) return FALSE;
 ctx->avc_encoder=rdp_avc_encoder_create((int)ctx->width,(int)ctx->height,60,12000000);
 rdp_gfx_runtime_init(&ctx->gfx_runtime,enabled,ctx->avc_encoder!=NULL);
 if (!ctx->avc_encoder) return FALSE;
 ctx->rdpgfx=rdpgfx_server_context_new(ctx->vcm);
 if (!ctx->rdpgfx) goto fail;
 ctx->rdpgfx->rdpcontext=peer->context;
 ctx->rdpgfx->custom=ctx;
 ctx->rdpgfx->CapsAdvertise=peer_gfx_caps_advertise;
 ctx->rdpgfx->FrameAcknowledge=peer_gfx_frame_acknowledge;
 if (!freerdp_settings_set_bool(settings,FreeRDP_GfxAVC444,FALSE) ||
     !freerdp_settings_set_bool(settings,FreeRDP_GfxH264,TRUE) ||
     !freerdp_settings_set_bool(settings,FreeRDP_SupportGraphicsPipeline,TRUE) ||
     !ctx->rdpgfx->Initialize || !ctx->rdpgfx->Initialize(ctx->rdpgfx,TRUE))
  goto fail;
 return TRUE;
fail:
 if (ctx->rdpgfx) { rdpgfx_server_context_free(ctx->rdpgfx); ctx->rdpgfx=NULL; }
 if (ctx->avc_encoder) { rdp_avc_encoder_destroy(ctx->avc_encoder); ctx->avc_encoder=NULL; }
 (void)freerdp_settings_set_bool(settings,FreeRDP_GfxH264,FALSE);
 (void)freerdp_settings_set_bool(settings,FreeRDP_SupportGraphicsPipeline,FALSE);
 rdp_gfx_runtime_init(&ctx->gfx_runtime,FALSE,FALSE);
 return FALSE;
}

static BOOL peer_gfx_disable_before_surface(peer_context *ctx) {
 if (!ctx || !rdp_gfx_runtime_can_fallback_raw(&ctx->gfx_runtime)) return FALSE;
 ctx->gfx_runtime.phase=RDP_GFX_RUNTIME_FAILED;
 if (ctx->rdpgfx) { rdpgfx_server_context_free(ctx->rdpgfx); ctx->rdpgfx=NULL; }
 if (ctx->avc_encoder) { rdp_avc_encoder_destroy(ctx->avc_encoder); ctx->avc_encoder=NULL; }
 return TRUE;
}
#endif

static void peer_context_cleanup(freerdp_peer *peer,rdpContext *base) {
 peer_context *ctx=(peer_context *)base;
 /* The clipboard cleanup below may need the job; the peer's ContextExtra is
  * still valid here (run_peer clears the jobs[] slot only after context_free). */
 peer_job *job=peer ? peer->ContextExtra : NULL;
 server_options *options=job ? job->options : NULL;
 free(ctx->last_desktop);
 ctx->last_desktop=NULL;
 free(ctx->rectangles);
 ctx->rectangles=NULL;ctx->rectangle_capacity=0;
 free(ctx->encoded_buffer);
 ctx->encoded_buffer=NULL;ctx->encoded_capacity=0;
 free(ctx->scale_x);
 ctx->scale_x=NULL;ctx->scale_x_width=0;ctx->scale_x_source_width=0;
 if(ctx->nsc_encoder){nsc_context_free(ctx->nsc_encoder);ctx->nsc_encoder=NULL;}
 if(ctx->nsc_stream){Stream_Free(ctx->nsc_stream,TRUE);ctx->nsc_stream=NULL;}
 if(ctx->disp){
  fprintf(stderr,"event=disp_channel_closed opened=%u ts_ms=%llu\n",
   ctx->disp_opened?1u:0u,disp_now_ms());fflush(stderr);
  disp_server_context_free(ctx->disp);ctx->disp=NULL;
 }
 if(ctx->resize_event){CloseHandle(ctx->resize_event);ctx->resize_event=NULL;}
 if(ctx->cliprdr) {
  if(ctx->cliprdr->Stop) (void)ctx->cliprdr->Stop(ctx->cliprdr);
  /* The cliprdr thread is joined: abort any in-flight remote->local offer so the
   * Agent can delete its half-written temp directory, then release the state. */
  cliprdr_peer_cleanup_stream(ctx);
  cliprdr_server_context_free(ctx->cliprdr);
  ctx->cliprdr=NULL;
 }
 /* Display restore (IPC type 17): the Agent may have switched the macOS display
  * mode for this session. Sent exactly once per peer teardown, after
  * the cliprdr channel stopped, only when this peer actually activated (an
  * activated peer is the one that requested a capture size / could have changed
  * the display mode). Empty payload; the Agent ignores it if no mode was saved. */
 if(options && ctx->ready) {
  const BOOL sent=send_agent_message(options,AGENT_IPC_TYPE_DISPLAY_RESTORE,NULL,0);
  fprintf(stderr,"event=display_restore_sent result=%u\n",sent?0u:1u);fflush(stderr);
 }
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
 if (ctx->rdpgfx) { rdpgfx_server_context_free(ctx->rdpgfx); ctx->rdpgfx=NULL; }
 if (ctx->avc_encoder) { rdp_avc_encoder_destroy(ctx->avc_encoder); ctx->avc_encoder=NULL; }
#endif
 if(ctx->vcm && ctx->vcm!=INVALID_HANDLE_VALUE) {
  WTSCloseServer(ctx->vcm);
  ctx->vcm=NULL;
 }
}

/* Client-driven output suppression (minimise / restore).
 *
 * FreeRDP's shared rdpUpdate struct wires SuppressOutput to
 * update_send_suppress_output even for server peers, so without this handler a
 * server would ECHO the client's TS_SUPPRESS_OUTPUT_PDU back to it. That is a
 * protocol violation: the Windows 11 client drops the session with a transport
 * error the moment the window is minimised, and the afterwards unreachable
 * session is the leaked single-session lease. Never send that PDU from a server:
 * record the state, stop sending updates while suppressed, and force one full
 * frame when the client asks for updates again. */
static BOOL peer_suppress_output(rdpContext *context,BYTE allow,const RECTANGLE_16 *area) {
 peer_context *ctx=(peer_context *)context;
 if (!ctx) return FALSE;
 BOOL suppressed=allow ? FALSE : TRUE;
 fprintf(stderr,"event=client_output_suppressed allow=%u suppressed=%u area=%u,%u,%u,%u\n",
   (unsigned)allow,(unsigned)suppressed,
   area ? (unsigned)area->left : 0,area ? (unsigned)area->top : 0,
   area ? (unsigned)area->right : 0,area ? (unsigned)area->bottom : 0);
 fflush(stderr);
 ctx->output_suppressed=suppressed;
 if (!suppressed) {
  /* The client was not receiving updates while minimised: repaint everything so
   * it does not restore a stale window. */
  ctx->force_full_frame=TRUE;
  ctx->drawn=FALSE;
 }
 return TRUE;
}

static BOOL configure_peer(freerdp_peer *peer, server_options *options) {
 peer->ContextSize=sizeof(peer_context);
 peer->ContextFree=peer_context_cleanup;
 if (!freerdp_peer_context_new(peer)) return FALSE;
  rdpSettings *s=peer->context->settings;
  peer_context *ctx=(peer_context *)peer->context;
  ctx->width=WIDTH;ctx->height=HEIGHT;
  if (!options->test_pattern) {
   pthread_mutex_lock(&options->frame_mutex);
   if (!options->frame_pixels || !options->frame_width || !options->frame_height) {
    pthread_mutex_unlock(&options->frame_mutex);
    return FALSE;
   }
   ctx->width=options->frame_width;ctx->height=options->frame_height;
   pthread_mutex_unlock(&options->frame_mutex);
  }
  rdpPrivateKey *key=freerdp_key_new_from_file_enc(options->key,NULL);
 rdpCertificate *cert=freerdp_certificate_new_from_file(options->cert);
 if (!key || !cert) {freerdp_key_free(key);freerdp_certificate_free(cert);return FALSE;}
 if (!freerdp_settings_set_pointer_len(s,FreeRDP_RdpServerRsaKey,key,1)) {freerdp_key_free(key);freerdp_certificate_free(cert);return FALSE;}
 if (!freerdp_settings_set_pointer_len(s,FreeRDP_RdpServerCertificate,cert,1)) {freerdp_certificate_free(cert);return FALSE;}
#define BOOL_SETTING(name,value) if (!freerdp_settings_set_bool(s,FreeRDP_##name,value)) return FALSE
#define UINT_SETTING(name,value) if (!freerdp_settings_set_uint32(s,FreeRDP_##name,value)) return FALSE
 BOOL_SETTING(RdpSecurity,FALSE);
 BOOL_SETTING(TlsSecurity,FALSE); /* disallow a TLS-only authentication bypass */
  BOOL_SETTING(NlaSecurity,TRUE);
  BOOL_SETTING(ExtSecurity,FALSE); /* P0 uses HYBRID NLA, not HYBRID_EX. */
  BOOL_SETTING(RdstlsSecurity,FALSE);
  BOOL_SETTING(AadSecurity,FALSE);
  BOOL_SETTING(Authentication,TRUE);
  BOOL_SETTING(RemoteFxCodec,FALSE);
  /* The NSCodec experiment is disabled in the production path: the live
   * session runs raw. Only the dedicated codec regression (which sets
   * RDP_TEST_NSCODEC_BITMAP=1 on the worker) advertises NSCodec. */
  const char *nscodec_test=getenv("RDP_TEST_NSCODEC_BITMAP");
  BOOL_SETTING(NSCodec,nscodec_test && nscodec_test[0]=='1');
   BOOL_SETTING(SupportGraphicsPipeline,FALSE);
   BOOL_SETTING(RefreshRect,TRUE);
   /* Advertise desktopResizeFlag in the Demand Active bitmap capability set so
    * clients accept the server-chosen size and the Deactivation-Reactivation
    * sequence used for client-driven resolution changes. */
   BOOL_SETTING(DesktopResize,TRUE);
  BOOL_SETTING(RedirectClipboard,options->clipboard_enabled);
  UINT_SETTING(DesktopWidth,ctx->width);
  UINT_SETTING(DesktopHeight,ctx->height);
 UINT_SETTING(ColorDepth,32);
  if (!freerdp_settings_set_string(s,FreeRDP_NtlmSamFile,options->sam)) return FALSE;
  ctx->vcm=WTSOpenServerA((LPSTR)peer->context);
  if(!ctx->vcm || ctx->vcm==INVALID_HANDLE_VALUE) return FALSE;
  /* Client-driven resolution adaptation: MS-RDPEDISP channel. The channel is
   * opened after PostConnect (see run_peer) and only record/signal from its
   * reader thread. */
  /* Manual-reset event: WinPR on Unix does not implement auto-reset events, so
   * SetEvent would leave the event permanently readable. The peer thread drains
   * it explicitly (see run_peer). */
  ctx->resize_event=CreateEvent(NULL,TRUE,FALSE,NULL);
  if (!ctx->resize_event) return FALSE;
  ctx->disp=disp_server_context_new(ctx->vcm);
  if (ctx->disp) {
   ctx->disp->custom=ctx;
   ctx->disp->MaxNumMonitors=1;
   ctx->disp->MaxMonitorAreaFactorA=8192;
   ctx->disp->MaxMonitorAreaFactorB=8192;
   ctx->disp->DispMonitorLayout=peer_disp_monitor_layout;
   ctx->disp->ChannelIdAssigned=peer_disp_channel_id_assigned;
  } else {
   fprintf(stderr,"event=disp_context_failed\n");fflush(stderr);
  }
  if(options->clipboard_enabled) {
   ctx->cliprdr=cliprdr_server_context_new(ctx->vcm);
   if(!ctx->cliprdr) return FALSE;
   ctx->cliprdr->rdpcontext=peer->context;
   ctx->cliprdr->custom=ctx;
   /* File clipboard capabilities (contract section 4): long format names, file
    * stream clipboard, no path obfuscation, and no huge (>2 GiB) file support.
    * These must be set before Start() sends CB_CLIP_CAPS / CB_MONITOR_READY. */
   ctx->cliprdr->useLongFormatNames=TRUE;
   ctx->cliprdr->streamFileClipEnabled=TRUE;
   ctx->cliprdr->fileClipNoFilePaths=FALSE;
   ctx->cliprdr->hasHugeFileSupport=FALSE;
   ctx->cliprdr->canLockClipData=FALSE;
   /* Do not let the FreeRDP channel thread auto-send the initialization
    * sequence: the peer thread must queue CB_CLIP_CAPS, CB_MONITOR_READY and the
    * first local CB_FORMAT_LIST strictly in that order (see post_connect). */
   ctx->cliprdr->autoInitializationSequence=FALSE;
   ctx->cliprdr->ClientFormatList=cliprdr_client_formats;
   ctx->cliprdr->ClientCapabilities=cliprdr_client_capabilities;
   ctx->cliprdr->ClientFormatDataResponse=cliprdr_client_data_response;
   ctx->cliprdr->ClientFileContentsResponse=cliprdr_client_file_contents_response;
   rdp_clipboard_set_callbacks(ctx->cliprdr,cliprdr_server_format_data_request);
   rdp_clipboard_set_file_contents_callback(ctx->cliprdr,cliprdr_server_file_contents_request);
  }
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
 (void)peer_gfx_initialize(peer,ctx,s);
#endif
 peer->SspiNtlmHashCallback=ntlm_hash;
 /* Override FreeRDP's client-side SuppressOutput sender (see peer_suppress_output). */
 peer->context->update->SuppressOutput=peer_suppress_output;
 peer->Logon=peer_logon;peer->PostConnect=peer_post_connect;peer->Activate=peer_activate;
 /* Negotiate the advertised desktop size before every Demand Active. */
 peer->Capabilities=peer_capabilities;
 peer->context->input->KeyboardEvent=keyboard;
 peer->context->input->UnicodeKeyboardEvent=unicode_keyboard;
 peer->context->input->MouseEvent=mouse;
 peer->context->input->ExtendedMouseEvent=mouse;
 peer->context->input->SynchronizeEvent=synchronize;
  peer->context->update->RefreshRect=refresh;
  if (!peer->Initialize(peer)) return FALSE;
  /* Opt-in transport capture for protocol debugging: RDP_TRANSPORT_DUMP=<path>
   * writes FreeRDP's record-framed TX/RX stream dump for this peer. It stays
   * disabled unless the environment variable is set, so production behavior
   * and the 0600 .runtime state stay untouched. */
  const char *dump_path=getenv("RDP_TRANSPORT_DUMP");
  if (dump_path && dump_path[0]) {
   if (!freerdp_settings_set_bool(s,FreeRDP_TransportDump,TRUE) ||
       !freerdp_settings_set_string(s,FreeRDP_TransportDumpFile,dump_path)) {
    fprintf(stderr,"event=transport_dump_config_failed\n");fflush(stderr);
   } else if (!stream_dump_register_handlers(peer->context,CONNECTION_STATE_INITIAL,TRUE)) {
    fprintf(stderr,"event=transport_dump_register_failed\n");fflush(stderr);
   } else {
    fprintf(stderr,"event=transport_dump_enabled path=%s\n",dump_path);fflush(stderr);
   }
  }
  peer_job *job=peer->ContextExtra;
  if (job) {
   job->original_redirection=peer->SendServerRedirection;
   if (job->original_redirection) peer->SendServerRedirection=peer_send_server_redirection_probe;
  }
  return TRUE;
}

static void *run_peer(void *argument) {
 peer_job *job=argument;
 freerdp_peer *peer=job->peer;
  /* Test-only hook: emulate a client that minimises and then restores its window
   * so the suppress-output handling (and the "server must not echo the PDU"
   * fix) is regression tested without needing a GUI client. Off by default. */
  UINT64 suppress_hook_ms=0,allow_hook_ms=0,session_start=0;
  BOOL suppress_hook_done=FALSE,allow_hook_done=FALSE;
  {
   const char *suppress_setting=getenv("RDP_TEST_SUPPRESS_OUTPUT_AT_MS");
   const char *allow_setting=getenv("RDP_TEST_ALLOW_OUTPUT_AT_MS");
   if (suppress_setting) suppress_hook_ms=strtoull(suppress_setting,NULL,10);
   if (allow_setting) allow_hook_ms=strtoull(allow_setting,NULL,10);
  }
  if (configure_peer(peer,job->options)) {
  for (;;) {
   peer_context *ctx=(peer_context *)peer->context;
   HANDLE handles[64];
   DWORD count=peer->GetEventHandles(peer,handles,60);
   if (!count || count>60) break;
   DWORD frame_index=count;
   handles[count++]=job->frame_event;
   DWORD resize_index=MAXDWORD;
   if (ctx->resize_event) { resize_index=count; handles[count++]=ctx->resize_event; }
   DWORD vcm_index=MAXDWORD;
   HANDLE vcm_event=ctx->vcm ? WTSVirtualChannelManagerGetEventHandle(ctx->vcm) : NULL;
   if (vcm_event && vcm_event!=INVALID_HANDLE_VALUE) { vcm_index=count; handles[count++]=vcm_event; }
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
   DWORD gfx_index=MAXDWORD;
   HANDLE gfx_event=ctx->rdpgfx ? rdpgfx_server_get_event_handle(ctx->rdpgfx) : NULL;
   if (gfx_event && gfx_event!=INVALID_HANDLE_VALUE) { gfx_index=count; handles[count++]=gfx_event; }
#endif
   DWORD wait_result=WaitForMultipleObjects(count,handles,FALSE,250);
   if (wait_result==WAIT_FAILED) break;
   /* Drain the manual-reset signals before processing. A signal that arrives
    * while the iteration runs stays set and wakes the next wait, so no frame or
    * resize request can be lost. */
   if (wait_result==WAIT_OBJECT_0+frame_index) ResetEvent(job->frame_event);
   if (resize_index!=MAXDWORD && wait_result==WAIT_OBJECT_0+resize_index)
    ResetEvent(ctx->resize_event);
   /* Enforce the handshake deadline on the peer's own thread. The listener
    * cannot shut this socket down: FreeRDP transfers socket ownership to the
    * transport during Initialize and clears peer->sockfd. */
   pthread_mutex_lock(&job->options->mutex);
   BOOL expired=GetTickCount64()>job->deadline;
   pthread_mutex_unlock(&job->options->mutex);
   if (expired) break;
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
   if (ctx->rdpgfx && ctx->gfx_runtime.phase==RDP_GFX_RUNTIME_ACTIVE &&
       rdp_gfx_ack_timed_out(&ctx->gfx_flow,GetTickCount64(),10000)) {
    fprintf(stderr,"event=gfx_avc420_ack_timeout pending=%u\n",ctx->gfx_flow.pending);
    break;
   }
   if (ctx->gfx_runtime.phase==RDP_GFX_RUNTIME_FAILED &&
       !rdp_gfx_runtime_can_fallback_raw(&ctx->gfx_runtime)) break;
#endif
    if (!peer->CheckFileDescriptor(peer)) {
     fprintf(stderr,"event=peer_transport_closed last_error=0x%08x ready=%u\n",
       (unsigned)freerdp_get_last_error(peer->context),ctx->ready);fflush(stderr);
     break;
    }
    /* A DISP monitor-layout request woke this thread: perform the
     * Deactivation-Reactivation here (never on the channel reader thread). */
    if (resize_index!=MAXDWORD && wait_result==WAIT_OBJECT_0+resize_index &&
        !peer_handle_pending_resize(peer)) break;
     /* Keep the single-session lease alive while this peer is the active
      * session. A peer that stops heartbeating (for example wedged on a
      * half-open TCP connection) lets a later login take the lease over
      * instead of denying every future login (2026-11-07 client error 0x904). */
     if (ctx->leased && ctx->ready && GetTickCount64()>=ctx->next_heartbeat) {
      goLeaseHeartbeat(ctx->lease_token);
      ctx->next_heartbeat=GetTickCount64()+1000;
     }
     /* A client that never answers CB_FILECONTENTS_REQUEST would keep a
      * remote->local offer open forever. Flag it here (lock-free, bounded); the
      * cliprdr channel thread aborts the offer on its next callback and the
      * Agent drops its half-written temp directory. */
     if (ctx->clip_file_stream_active && !ctx->clip_file_cancel_requested &&
         ctx->clip_file_last_activity &&
         GetTickCount64()-ctx->clip_file_last_activity>CLIPBOARD_FILE_STALL_MS) {
      ctx->clip_file_cancel_requested=TRUE;
      fprintf(stderr,"event=clipboard_file_stalled direction=remote_to_local\n");fflush(stderr);
     }
     if (ctx->ready && !suppress_hook_done && suppress_hook_ms) {
      if (!session_start) session_start=GetTickCount64();
      if (GetTickCount64()-session_start>=suppress_hook_ms) {
       (void)peer_suppress_output(peer->context,0,NULL);
       suppress_hook_done=TRUE;
      }
     }
     if (ctx->ready && !allow_hook_done && allow_hook_ms && suppress_hook_done) {
      if (GetTickCount64()-session_start>=allow_hook_ms) {
       (void)peer_suppress_output(peer->context,1,NULL);
       allow_hook_done=TRUE;
      }
     }
   BOOL vcm_signaled=(vcm_index!=MAXDWORD && wait_result==WAIT_OBJECT_0+vcm_index);
   if (ctx->vcm) {
    BOOL joined=WTSVirtualChannelManagerIsChannelJoined(ctx->vcm,DRDYNVC_SVC_CHANNEL_NAME);
    DWORD dvc_state=WTSVirtualChannelManagerGetDrdynvcState(ctx->vcm);
    if (vcm_signaled || (joined && dvc_state==DRDYNVC_STATE_NONE)) {
     /* Never auto-open DRDYNVC (which writes the 4-byte DVC Capabilities
      * Request on the drdynvc channel) before the connection sequence has
      * completed. Virtual Channel PDUs are only legal after Demand Active /
      * Confirm Active; Microsoft clients parse an early DVC capabilities PDU
      * (no security header) as a Server Redirection PDU and abort. The Ex
      * variant still drains VCM messages with auto-open disabled; once
      * peer->connected is set by PostConnect the same branch opens DRDYNVC
      * exactly like a Microsoft server, after finalization. */
     if (!WTSVirtualChannelManagerCheckFileDescriptorEx(ctx->vcm,peer->connected)) break;
     joined=WTSVirtualChannelManagerIsChannelJoined(ctx->vcm,DRDYNVC_SVC_CHANNEL_NAME);
     dvc_state=WTSVirtualChannelManagerGetDrdynvcState(ctx->vcm);
    }
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
    if (ctx->rdpgfx && ctx->gfx_runtime.phase==RDP_GFX_RUNTIME_WAIT_DRDYNVC &&
        dvc_state==DRDYNVC_STATE_FAILED) {
     (void)rdp_gfx_runtime_channel_opened(&ctx->gfx_runtime,FALSE);
     if (!peer_gfx_disable_before_surface(ctx)) break;
    }
    if (ctx->rdpgfx && rdp_gfx_runtime_should_open(&ctx->gfx_runtime,joined,
                                                    dvc_state==DRDYNVC_STATE_READY)) {
     BOOL opened=ctx->rdpgfx->Open && ctx->rdpgfx->Open(ctx->rdpgfx);
     if (!rdp_gfx_runtime_channel_opened(&ctx->gfx_runtime,opened) &&
         !peer_gfx_disable_before_surface(ctx)) break;
    }
    if (ctx->rdpgfx && gfx_index!=MAXDWORD &&
        wait_result==WAIT_OBJECT_0+gfx_index &&
        rdpgfx_server_handle_messages(ctx->rdpgfx)!=CHANNEL_RC_OK &&
        !peer_gfx_disable_before_surface(ctx)) break;
#endif
    /* Open the DISP channel only after PostConnect and once DRDYNVC is ready,
     * exactly like the GFX channel above. A client that does not support it just
     * never sends a monitor layout; behaviour is unchanged. */
    if (ctx->disp && !ctx->disp_opened && !ctx->disp_failed) {
     if (disp_debug_enabled()) {
      UINT32 state=(joined?1u:0u)|(dvc_state==DRDYNVC_STATE_READY?2u:0u)|
                   (peer->connected?4u:0u);
      if (state!=ctx->disp_debug_state) {
       ctx->disp_debug_state=state;
       fprintf(stderr,"event=disp_debug_state joined=%u dvc_ready=%u connected=%u ts_ms=%llu\n",
        joined?1u:0u,dvc_state==DRDYNVC_STATE_READY?1u:0u,peer->connected?1u:0u,
        disp_now_ms());fflush(stderr);
      }
     }
     if (peer->connected && joined && dvc_state==DRDYNVC_STATE_READY) {
      if (ctx->disp->Open && ctx->disp->Open(ctx->disp)==CHANNEL_RC_OK) {
       ctx->disp_opened=TRUE;
       fprintf(stderr,"event=disp_channel_opened result=0 ts_ms=%llu\n",
        disp_now_ms());fflush(stderr);
       if (ctx->disp->DisplayControlCaps) {
        UINT rc=ctx->disp->DisplayControlCaps(ctx->disp);
        fprintf(stderr,"event=disp_caps_sent result=%u max_monitors=%u area_a=%u area_b=%u ts_ms=%llu\n",
         rc,ctx->disp->MaxNumMonitors,ctx->disp->MaxMonitorAreaFactorA,
         ctx->disp->MaxMonitorAreaFactorB,disp_now_ms());fflush(stderr);
       }
      } else {
       ctx->disp_failed=TRUE;
       fprintf(stderr,"event=disp_channel_opened result=1 ts_ms=%llu\n",
        disp_now_ms());fflush(stderr);
      }
     }
    }
   }
   /* Coalesce input callbacks and send outside handshake/receive callbacks.
    * The P0 screen has two states, so identical frames are never queued. */
    pthread_mutex_lock(&job->options->frame_mutex);
    BOOL has_new_frame=rdp_frame_is_new(job->options->frame_generation,
       job->options->frame_id,ctx->last_frame_generation,ctx->last_frame_id);
    pthread_mutex_unlock(&job->options->frame_mutex);
    if (ctx->ready && !ctx->output_suppressed && (!ctx->drawn || has_new_frame || ((ctx->inputs & 3)==3 && !ctx->echoed)
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
        || rdp_gfx_refresh_ready(&ctx->gfx_flow)
#endif
       )) {
     if (!draw_pattern_with_deadline(peer)) break;
     ctx->drawn=TRUE;ctx->echoed=(ctx->inputs & 3)==3;
   }
  }
  } else fprintf(stderr,"event=peer_configure_failed\n");
   if (peer->context) {
    peer_context *ctx=(peer_context *)peer->context;
    fprintf(stderr,"event=peer_loop_ended leased=%u ready=%u drawn=%u last_error=0x%08x\n",
      ctx->leased,ctx->ready,ctx->drawn,(unsigned)freerdp_get_last_error(peer->context));fflush(stderr);
   if (ctx->leased) {
    peer_job *job=peer->ContextExtra;
    if(job && !job->options->test_pattern) {
     BYTE release_input[9]={4};
     (void)send_agent_input(job->options,release_input,sizeof(release_input));
    }
    goRelease(ctx->lease_token);
   }
  peer->Disconnect(peer);
  freerdp_peer_context_free(peer);
 }
 /* Remove the fd under the watchdog lock before closing it. Keep FreeRDP
  * teardown outside our mutex to avoid lock inversion with native threads. */
   pthread_mutex_lock(&job->options->mutex);
   job->options->jobs[job->slot]=NULL;
   pthread_mutex_unlock(&job->options->mutex);
   CloseHandle(job->frame_event);
  if (job->cancel_fd>=0) close(job->cancel_fd);
  freerdp_peer_free(peer);
 free(job);
 return NULL;
}
static BOOL accept_peer(freerdp_listener *listener, freerdp_peer *peer) {
 server_options *options=listener->info;
 pthread_mutex_lock(&options->mutex);
 unsigned slot=0;
 for (;slot<MAX_PEERS;slot++) if (!options->jobs[slot]) break;
 if (slot==MAX_PEERS) {pthread_mutex_unlock(&options->mutex);return FALSE;}
  peer_job *job=calloc(1,sizeof(*job));
  if (!job) {pthread_mutex_unlock(&options->mutex);return FALSE;}
  /* Manual-reset event: WinPR on Unix does not implement auto-reset events (the
   * eventfd is never drained by WaitForMultipleObjects). The peer thread drains
   * it explicitly in run_peer; without that, the event stays readable forever
   * after the first Agent frame and can starve every later signal (this is what
   * made a second client-driven resize invisible). */
  job->frame_event=CreateEvent(NULL,TRUE,FALSE,NULL);
  if (!job->frame_event) {free(job);pthread_mutex_unlock(&options->mutex);return FALSE;}
  job->cancel_fd=dup(peer->sockfd);
  if (job->cancel_fd<0) {CloseHandle(job->frame_event);free(job);pthread_mutex_unlock(&options->mutex);return FALSE;}
   /* Detect half-open client connections instead of letting a peer thread wait
    * forever on a silently dropped WiFi/VPN link (macOS defaults are hours).
    * This is the transport-level half of the leaked-lease fix. */
   {
    int keepalive=1,idle=10,interval=5,count=3;
    (void)setsockopt(peer->sockfd,SOL_SOCKET,SO_KEEPALIVE,&keepalive,sizeof(keepalive));
#ifdef TCP_KEEPALIVE
    (void)setsockopt(peer->sockfd,IPPROTO_TCP,TCP_KEEPALIVE,&idle,sizeof(idle));
#endif
#ifdef TCP_KEEPINTVL
    (void)setsockopt(peer->sockfd,IPPROTO_TCP,TCP_KEEPINTVL,&interval,sizeof(interval));
#endif
#ifdef TCP_KEEPCNT
    (void)setsockopt(peer->sockfd,IPPROTO_TCP,TCP_KEEPCNT,&count,sizeof(count));
#endif
   }
 (void)fcntl(job->cancel_fd,F_SETFD,FD_CLOEXEC);
 job->peer=peer;job->options=options;job->slot=slot;job->deadline=GetTickCount64()+15000;
 peer->ContextExtra=job;
 options->jobs[slot]=job;
  pthread_t thread;
  if (pthread_create(&thread,NULL,run_peer,job)!=0) {
    options->jobs[slot]=NULL;close(job->cancel_fd);CloseHandle(job->frame_event);free(job);pthread_mutex_unlock(&options->mutex);return FALSE;
  }
 pthread_detach(thread);
 pthread_mutex_unlock(&options->mutex);
 return TRUE;
}

int rdp_serve(const char *address,int port,const char *cert,const char *key,const char *sam,const char *agent_socket,int test_pattern,int clipboard) {
 install_worker_crash_backtrace();
 if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 1;
 if (!WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi())) return 1;
 if (!private_agent_socket_path(agent_socket)) {
  fprintf(stderr,"Agent IPC socket requires an absolute path in an owned private directory\n");
  return 1;
 }
 /* Lifetime matches this process. The Go wrapper invokes this once. */
 server_options *options=calloc(1,sizeof(*options));
 if (!options) return 1;
 options->cert=strdup(cert);options->key=strdup(key);options->sam=strdup(sam);options->agent_socket=strdup(agent_socket);
 if (!options->cert || !options->key || !options->sam || !options->agent_socket) return 1;
 pthread_mutex_init(&options->mutex,NULL);
 pthread_mutex_init(&options->frame_mutex,NULL);
 pthread_mutex_init(&options->agent_mutex,NULL);
 pthread_mutex_init(&options->clipboard_mutex,NULL);
 options->agent_client_fd=-1;
 options->test_pattern=test_pattern ? TRUE : FALSE;
 options->clipboard_enabled=clipboard ? TRUE : FALSE;
 pthread_t agent_thread;
 if (pthread_create(&agent_thread,NULL,agent_connection,options)!=0) return 1;
 pthread_detach(agent_thread);
 freerdp_listener *listener=freerdp_listener_new();
 if (!listener) return 1;
 listener->info=options;listener->PeerAccepted=accept_peer;
 if (!listener->Open(listener,address,(UINT16)port)) {freerdp_listener_free(listener);free(options);return 2;}
 fprintf(stderr,"event=listening\n");fflush(stderr);
 for (;;) {
  HANDLE handles[32];
  DWORD count=listener->GetEventHandles(listener,handles,32);
  if (!count || WaitForMultipleObjects(count,handles,FALSE,100)==WAIT_FAILED) break;
  if (!listener->CheckFileDescriptor(listener)) break;
  /* Initialize transfers peer->sockfd to FreeRDP's transport. Keep a dup so
   * this listener thread can interrupt a TLS/NLA wait or a blocked frame write. */
  pthread_mutex_lock(&options->mutex);
  UINT64 now=GetTickCount64();
  for (unsigned i=0;i<MAX_PEERS;i++) {
   peer_job *job=options->jobs[i];
   if (job && !job->cancelled && now>job->deadline) {
    job->cancelled=TRUE;
    (void)shutdown(job->cancel_fd,SHUT_RDWR);
    fprintf(stderr,"event=peer_deadline_expired slot=%u\n",i);
   }
  }
  pthread_mutex_unlock(&options->mutex);
 }
 listener->Close(listener);
 freerdp_listener_free(listener);
 /* Fatal listener failure terminates the worker process, including its peers.
  * Do not free options while detached peer threads can still access it. */
 return 3;
}

/* CRC-32 (IEEE 802.3) over the client framebuffer, so tests can assert that
 * incremental (dirty-rectangle) delivery converges to the same pixels as a
 * full-frame refresh. Not used by the production peer path. */
static UINT32 probe_crc_table[256];
static BOOL probe_crc_ready=FALSE;
static void probe_crc_init(void) {
 if (probe_crc_ready) return;
 for (UINT32 i=0;i<256;i++) {
  UINT32 value=i;
  for (int bit=0;bit<8;bit++) value=(value>>1)^(0xEDB88320u & (UINT32)-(int)(value&1u));
  probe_crc_table[i]=value;
 }
 probe_crc_ready=TRUE;
}
static UINT32 probe_crc32(const BYTE *data,size_t length) {
 probe_crc_init();
 UINT32 crc=0xFFFFFFFFu;
 for (size_t i=0;i<length;i++) crc=probe_crc_table[(crc^data[i])&0xFFu]^(crc>>8);
 return crc^0xFFFFFFFFu;
}
/* Only the three colour bytes per pixel take part: the ignored fourth (X/alpha)
 * byte is not part of the visible framebuffer and may differ between decoder
 * paths. Byte order is FreeRDP XRGB32 memory order (B,G,R,X). */
static UINT32 probe_framebuffer_crc(rdpGdi *gdi) {
 if (!gdi || !gdi->primary_buffer || !gdi->stride) return 0;
 probe_crc_init();
 UINT32 crc=0xFFFFFFFFu;
 for (UINT32 y=0;y<gdi->height;y++) {
  const BYTE *row=gdi->primary_buffer+(size_t)y*gdi->stride;
  for (UINT32 x=0;x<gdi->width;x++) {
   const BYTE *pixel=row+(size_t)x*4;
   crc=probe_crc_table[(crc^pixel[0])&0xFFu]^(crc>>8);
   crc=probe_crc_table[(crc^pixel[1])&0xFFu]^(crc>>8);
   crc=probe_crc_table[(crc^pixel[2])&0xFFu]^(crc>>8);
  }
 }
 return crc^0xFFFFFFFFu;
}

/* Headless development probe. Mode 3 stops reading after sending input to test
 * server-side write cancellation under receive backpressure.
 *
 * Resolution-adaptation probes (2026-11-07):
 *  - mode 5 pixel sampling: RDP_PROBE_SAMPLE_POINTS="x:y,x:y,..." prints
 *    "sample x= y= bgra=b,g,r,a" after the first full desktop frame.
 *  - mode 10 client-driven resize: RDP_PROBE_RESIZE_AT_MS/WIDTH/HEIGHT sends an
 *    MS-RDPEDISP monitor layout after the first frame and verifies the server
 *    reactivates to the negotiated size and delivers a frame there.
 *
 * Clipboard file probes (2026-11-08, Issue 3):
 *  - mode 11 emulates a Windows client pasting files (Windows -> macOS): it
 *    offers FileGroupDescriptorW(0xC003)/FileContents(0xC004), answers the
 *    server descriptor request with a packed file list built in-probe and
 *    serves CB_FILECONTENTS_REQUEST ranges of deterministic test data.
 *    Env: RDP_PROBE_FILE_COUNT(1..3, default 1), RDP_PROBE_FILE_SIZE bytes
 *    (default 1024, per file: RDP_PROBE_FILE_SIZE2/3 override), file names
 *    RDP_PROBE_FILE_NAME (default "probe-file.bin"), ..._NAME2/3. Test data
 *    bytes are (j*31 + i*97 + 13) & 0xFF. Prints "format_list_sent",
 *    "descriptor_requested", "descriptor_sent bytes=N",
 *    "file_contents_request lindex=I offset=O len=L",
 *    "file_contents_sent bytes=N" and finally "file_paste_ok files=N bytes=M".
 *  - mode 12 emulates the same client pasting a file list the server
 *    advertises (macOS -> Windows): waits for the server CB_FORMAT_LIST with
 *    0xC003, requests the descriptor, then per file FILECONTENTS_SIZE
 *    (cbRequested=8) and FILECONTENTS_RANGE chunks of RDP_PROBE_CLIP_CHUNK
 *    bytes (default 65536), verifying each file against
 *    RDP_PROBE_FILE_SHA256 (comma separated lowercase/uppercase hex). Prints
 *    "format_list_received", "descriptor_request_sent", "descriptor_received
 *    files=N", "file_size_request/file_size_ok lindex=I size=N",
 *    "file_contents_request/file_contents_received",
 *    "file_contents_ok lindex=I bytes=N sha256=..." and "file_paste_ok".
 *    RDP_PROBE_OVERLONG_RANGE=1 reproduces mstsc.exe's paste behaviour: every
 *    RANGE request (including the last one) asks for the full chunk size
 *    (262144 by default, RDP_PROBE_CLIP_CHUNK overrides) even when
 *    offset+chunk exceeds the file size, and a SHORT final
 *    CB_FILECONTENTS_RESPONSE is accepted; each short response additionally
 *    prints "file_contents_short_response lindex=I requested=R got=G" and the
 *    whole-file sha256/file_paste_ok lines are unchanged. Defaults keep the
 *    previous exact-remaining chunking and stdout byte-compatible.
 *  - both modes: RDP_PROBE_CLIP_TIMEOUT_MS (default 20000) deadline; on
 *    timeout/failure they print "file_paste_failed reason=... stage=..." and
 *    exit 22. No agent frames are needed: the cliprdr channel runs on its own
 *    thread, so tests drive the worker IPC side independently.
 *  - mode 11 error-path injection: RDP_PROBE_FAIL_CONTENTS=response_fail
 *    answers the first FILECONTENTS_RANGE request with CB_RESPONSE_FAIL and
 *    =short_response (alias size_mismatch) with half of the requested bytes;
 *    both print "fail_injection kind=... lindex=... offset=... len=...", then
 *    fail with "file_paste_failed reason=client_error stage=injected_*"
 *    (rc 22) so the worker's client_failed abort can be asserted.
 *  - mode 11 name passthrough: RDP_PROBE_FILE_NAME="" is honoured as an empty
 *    cFileName (unless overwritten), and RDP_PROBE_CLIP_UNSAFE_NAME=1 skips the
 *    probe-side <=255-byte name check so over-long names reach the worker's
 *    descriptor validation (expected rejection: reason=bad_name). */
#include <freerdp/client/cliprdr.h>
#include <freerdp/utils/cliprdr_utils.h>

#define PROBE_CLIP_FILE_MAX 3
#define PROBE_CLIP_FILE_NAME_MAX 256
#define PROBE_CLIP_RX_MAX_FILES 16
#define PROBE_CLIP_RX_MAX_BYTES (64u*1024u*1024u)
#define PROBE_CLIP_TIMEOUT_DEFAULT 20000

typedef struct {
 char name[PROBE_CLIP_FILE_NAME_MAX];
 UINT64 size;
 BYTE *content;
} probe_clip_offer_file;

typedef struct {
 char name[260];
 UINT64 size;
 UINT64 received;
 BYTE *data;
} probe_clip_rx_file;

 typedef struct {
  rdpContext context;
  BOOL frame,input_seen,bitmap_seen,bitmap_compressed,surface_bits_seen,gfx_mode,gfx_paint_seen;
  UINT32 bitmap_bpp,bitmap_flags,bitmap_length,width,height;
  UINT32 bitmap_updates,bitmap_rectangles,surface_codec,surface_length;
  UINT64 bitmap_bytes;
  pBitmapUpdate bitmap_update;pSurfaceBits surface_bits;
  int mode;
  DispClientContext *disp;
  UINT32 requested_width,requested_height;
  BOOL reactivated;
  UINT32 reactivated_width,reactivated_height;
  BOOL samples_done;
  UINT32 resize_width,resize_height;
  BOOL resize_sent,resize_frame;
  UINT32 bitmap_rectangles_at_resize;
  /* Optional second sequential client-driven resize in the same session. */
  UINT32 resize2_width,resize2_height;
  UINT64 resize2_at_ms;
  BOOL resize2_sent,resize2_frame;
  UINT32 bitmap_rectangles_at_resize2;
  UINT32 reactivation_count;
  UINT64 resize_started;
  /* cliprdr file-clipboard probes (modes 11/12). The callbacks run on the
   * cliprdr channel thread; clip_mutex guards the state the main loop polls. */
  CliprdrClientContext *cliprdr;
  BOOL clip_mutex_init;
  pthread_mutex_t clip_mutex;
  UINT32 clip_timeout_ms,clip_chunk;
  UINT32 clip_bytes;
  BOOL clip_monitor_ready,clip_format_list_sent,clip_descriptor_sent;
  BOOL clip_done,clip_failed,clip_reported;
  UINT64 clip_done_at,clip_failed_at;
  const char *clip_stage;
  /* Deliberate client-side failure injection and unsafe-name passthrough for
   * the worker's rejection-path tests (mode 11). */
  int clip_fail_contents;
  BOOL clip_fail_injected;
  BOOL clip_unsafe_name;
  /* Mode 12: request the full chunk size even for the last chunk (mstsc field
   * behaviour, 2026-11-08) and expect a SHORT final CB_FILECONTENTS_RESPONSE. */
  BOOL clip_overlong_range;
  /* Mode 11 dynamic-format-id emulation (RDP_PROBE_DYNAMIC_FORMAT_IDS=1):
   * mstsc.exe advertises registered clipboard formats with DYNAMIC ids plus
   * long names (field evidence 2026-11-08: 49314 FileGroupDescriptorW,
   * 49269 FileContents, 49319 Preferred DropEffect, 49337 ZoneIdentifier).
   * The probe then answers CB_FORMAT_DATA_REQUEST only for the advertised
   * descriptor id, exactly like mstsc; a fixed-id request (0xC003) is failed.
   * Defaults keep mode 11 byte-compatible with the standard fixed ids. */
  BOOL clip_dynamic_format_ids;
  UINT32 clip_descriptor_format_id;
  UINT32 clip_contents_format_id;
  /* Mode 11: files this probe client offers to the server. */
  UINT32 clip_offer_count,clip_offer_bytes;
  probe_clip_offer_file *clip_offer;
  UINT64 *clip_offer_served;
  FILEDESCRIPTORW *clip_offer_desc;
  BYTE *clip_offer_list;
  UINT32 clip_offer_list_len;
  /* Mode 12: the file list the server advertises and the probe requests. */
  UINT32 clip_rx_count,clip_rx_index,clip_rx_stream,clip_rx_kind;
  UINT64 clip_rx_offset;
  UINT32 clip_rx_request_len;
  BYTE *clip_rx_descriptor;
  UINT32 clip_rx_descriptor_len;
  probe_clip_rx_file *clip_rx;
  char **clip_expected_sha;
  UINT32 clip_expected_count;
  BOOL clip_sha_expected;
 } probe_context;
static BOOL probe_bitmap_update(rdpContext *context,const BITMAP_UPDATE *bitmap) {
 probe_context *p=(probe_context *)context;
 if (bitmap && bitmap->number>0) {
  p->bitmap_updates++;
  p->bitmap_rectangles+=bitmap->number;
  p->bitmap_seen=TRUE;
  if (bitmap->rectangles) {
   for (UINT32 i=0;i<bitmap->number;i++) p->bitmap_bytes+=bitmap->rectangles[i].bitmapLength;
    p->bitmap_bpp=bitmap->rectangles[0].bitsPerPixel;
    p->bitmap_compressed=bitmap->rectangles[0].compressed;
    p->bitmap_flags=bitmap->rectangles[0].flags;
   if (bitmap->rectangles[0].bitmapLength>p->bitmap_length)
    p->bitmap_length=bitmap->rectangles[0].bitmapLength;
  }
 }
 return p->bitmap_update ? p->bitmap_update(context,bitmap) : FALSE;
}
static BOOL probe_surface_bits(rdpContext *context,const SURFACE_BITS_COMMAND *command) {
 probe_context *p=(probe_context *)context;
 if(command) {
  p->surface_bits_seen=TRUE;
  p->surface_codec=command->bmp.codecID;
  p->surface_length=command->bmp.bitmapDataLength;
 }
 return p->surface_bits ? p->surface_bits(context,command) : FALSE;
}
static BOOL probe_paint(rdpContext *context) {
 probe_context *p=(probe_context *)context;
 if (context->gdi && context->gdi->primary_buffer) {
  BYTE first=context->gdi->primary_buffer[3]; /* XRGB32 byte order */
  rdpGdi *gdi=context->gdi;
   if (gdi->width!=p->width || gdi->height!=p->height) return FALSE;
   if (p->gfx_mode) p->gfx_paint_seen=TRUE;
   BYTE last=gdi->primary_buffer[(p->height-1)*(size_t)gdi->stride+(p->width-1)*4+3];
  if (first==0x20 && last==0x20) p->frame=TRUE;
  if (first==0x80 && last==0x80 && p->frame) p->input_seen=TRUE;
  if (first==0x80 && last==0x80 && p->surface_bits_seen) p->frame=TRUE;
 }
 return TRUE;
}
static UINT32 probe_env_uint(const char *name,UINT32 fallback,UINT32 minimum,UINT32 maximum) {
 const char *value=getenv(name);
 if (!value || !value[0]) return fallback;
 char *end=NULL;
 unsigned long parsed=strtoul(value,&end,10);
 if (end==value) return fallback;
 if (parsed<minimum) parsed=minimum;
 if (parsed>maximum) parsed=maximum;
 return (UINT32)parsed;
}
static BOOL probe_env_flag(const char *name) {
 const char *value=getenv(name);
 if (!value || !value[0]) return FALSE;
 return strcmp(value,"0")!=0 && strcmp(value,"false")!=0 && strcmp(value,"FALSE")!=0;
}
static const char *probe_env_string(const char *name,const char *fallback) {
 const char *value=getenv(name);
 return (value && value[0]) ? value : fallback;
}
/* Explicitly-set-but-empty wins: used for file names, where an empty value is a
 * deliberate rejection-test input rather than "unset". */
static const char *probe_env_string_exact(const char *name,const char *fallback) {
 const char *value=getenv(name);
 return value ? value : fallback;
}

/* ------- cliprdr file-clipboard probe (modes 11/12), 2026-11-08 Issue 3 ----
 * Mode 11 acts as the Windows client that offers files: it answers the
 * server's CB_FORMAT_DATA_REQUEST for FileGroupDescriptorW with a packed
 * FILEDESCRIPTORW list built in-probe and serves CB_FILECONTENTS_REQUEST
 * ranges. Mode 12 acts as the Windows client pasting the server's file list:
 * it requests the descriptor, per-file FILECONTENTS_SIZE and FILECONTENTS_RANGE
 * chunks and verifies the sha256. Chunked transfer state is only touched from
 * the cliprdr channel thread; the main loop polls clip_done/clip_failed. */
static void probe_clip_sha256_block(UINT32 h[8],const BYTE *block) {
 static const UINT32 k[64]={
  0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
  0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
  0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
  0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
  0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
  0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
  0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
  0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u};
 UINT32 w[64];
 for (int i=0;i<16;i++) w[i]=((UINT32)block[i*4]<<24)|((UINT32)block[i*4+1]<<16)|((UINT32)block[i*4+2]<<8)|(UINT32)block[i*4+3];
 for (int i=16;i<64;i++) {
  UINT32 s0=((w[i-15]>>7)|(w[i-15]<<25))^((w[i-15]>>18)|(w[i-15]<<14))^(w[i-15]>>3);
  UINT32 s1=((w[i-2]>>17)|(w[i-2]<<15))^((w[i-2]>>19)|(w[i-2]<<13))^(w[i-2]>>10);
  w[i]=w[i-16]+s0+w[i-7]+s1;
 }
 UINT32 a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
 for (int i=0;i<64;i++) {
  UINT32 S1=((e>>6)|(e<<26))^((e>>11)|(e<<21))^((e>>25)|(e<<7));
  UINT32 ch=(e&f)^((~e)&g);
  UINT32 t1=hh+S1+ch+k[i]+w[i];
  UINT32 S0=((a>>2)|(a<<30))^((a>>13)|(a<<19))^((a>>22)|(a<<10));
  UINT32 maj=(a&b)^(a&c)^(b&c);
  UINT32 t2=S0+maj;
  hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
 }
 h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
}
static void probe_clip_sha256(const BYTE *data,size_t length,BYTE digest[32]) {
 UINT32 h[8]={0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};
 size_t offset=0;
 while (length-offset>=64) {probe_clip_sha256_block(h,data+offset);offset+=64;}
 size_t remaining=length-offset;
 BYTE tail[128]={0};
 if (remaining && data) memcpy(tail,data+offset,remaining);
 tail[remaining]=0x80;
 size_t blocks=(remaining<56)?1:2;
 UINT64 bits=(UINT64)length*8u;
 for (int i=0;i<8;i++) tail[blocks*64-1-i]=(BYTE)((bits>>(8*i))&0xFFu);
 for (size_t b=0;b<blocks;b++) probe_clip_sha256_block(h,tail+b*64);
 for (int i=0;i<8;i++) {
  digest[i*4]=(BYTE)((h[i]>>24)&0xFFu);digest[i*4+1]=(BYTE)((h[i]>>16)&0xFFu);
  digest[i*4+2]=(BYTE)((h[i]>>8)&0xFFu);digest[i*4+3]=(BYTE)(h[i]&0xFFu);
 }
}
static void probe_clip_hex(const BYTE *data,size_t length,char *out) {
 static const char digits[]="0123456789abcdef";
 for (size_t i=0;i<length;i++) {out[i*2]=digits[data[i]>>4];out[i*2+1]=digits[data[i]&0x0Fu];}
 out[length*2]='\0';
}
static probe_context *probe_clip_from(CliprdrClientContext *cliprdr) {
 return cliprdr ? (probe_context *)cliprdr->custom : NULL;
}
static void probe_clip_set_stage(probe_context *p,const char *stage) {
 pthread_mutex_lock(&p->clip_mutex);
 p->clip_stage=stage;
 pthread_mutex_unlock(&p->clip_mutex);
}
static void probe_clip_fail(probe_context *p,const char *stage) {
 pthread_mutex_lock(&p->clip_mutex);
 p->clip_failed=TRUE;p->clip_stage=stage;p->clip_failed_at=GetTickCount64();
 pthread_mutex_unlock(&p->clip_mutex);
}
static void probe_clip_mark_done(probe_context *p) {
 pthread_mutex_lock(&p->clip_mutex);
 p->clip_done=TRUE;p->clip_done_at=GetTickCount64();p->clip_stage="done";
 pthread_mutex_unlock(&p->clip_mutex);
}
static BOOL probe_clip_send_caps(probe_context *p) {
 if (!p->cliprdr || !p->cliprdr->ClientCapabilities) return FALSE;
 CLIPRDR_GENERAL_CAPABILITY_SET general={0};
 CLIPRDR_CAPABILITIES caps={0};
 general.capabilitySetType=CB_CAPSTYPE_GENERAL;
 general.capabilitySetLength=CB_CAPSTYPE_GENERAL_LEN;
 general.version=CB_CAPS_VERSION_2;
 general.generalFlags=CB_USE_LONG_FORMAT_NAMES|CB_STREAM_FILECLIP_ENABLED;
 caps.cCapabilitiesSets=1;
 caps.capabilitySets=(CLIPRDR_CAPABILITY_SET *)&general;
 return p->cliprdr->ClientCapabilities(p->cliprdr,&caps)==CHANNEL_RC_OK;
}
/* Mode 12 request helpers: only called from the cliprdr channel thread. */
static void probe_clip_request_size(probe_context *p,UINT32 index) {
 CLIPRDR_FILE_CONTENTS_REQUEST request={0};
 p->clip_rx_index=index;p->clip_rx_kind=1;p->clip_rx_offset=0;
 request.common.msgType=CB_FILECONTENTS_REQUEST;
 request.streamId=p->clip_rx_stream;
 request.listIndex=index;
 request.dwFlags=FILECONTENTS_SIZE;
 request.nPositionLow=0;request.nPositionHigh=0;
 request.cbRequested=8;
 if (!p->cliprdr || !p->cliprdr->ClientFileContentsRequest ||
     p->cliprdr->ClientFileContentsRequest(p->cliprdr,&request)!=CHANNEL_RC_OK) {
  probe_clip_fail(p,"file_size_request");
  return;
 }
 printf("file_size_request lindex=%u\n",(unsigned)index);
 fflush(stdout);
}
static void probe_clip_request_range(probe_context *p) {
 UINT32 index=p->clip_rx_index;
 probe_clip_rx_file *file=&p->clip_rx[index];
 UINT64 offset=p->clip_rx_offset;
 UINT64 remaining=file->size-offset;
 /* mstsc field behaviour (RDP_PROBE_OVERLONG_RANGE): always ask for one full
  * chunk, even when it runs past EOF; the server answers the short remainder. */
 UINT32 length=p->clip_overlong_range ? p->clip_chunk :
  (UINT32)(remaining>p->clip_chunk ? p->clip_chunk : remaining);
 CLIPRDR_FILE_CONTENTS_REQUEST request={0};
 p->clip_rx_kind=2;p->clip_rx_request_len=length;
 request.common.msgType=CB_FILECONTENTS_REQUEST;
 request.streamId=p->clip_rx_stream;
 request.listIndex=index;
 request.dwFlags=FILECONTENTS_RANGE;
 request.nPositionLow=(UINT32)(offset&0xFFFFFFFFu);
 request.nPositionHigh=(UINT32)(offset>>32);
 request.cbRequested=length;
 if (!p->cliprdr || !p->cliprdr->ClientFileContentsRequest ||
     p->cliprdr->ClientFileContentsRequest(p->cliprdr,&request)!=CHANNEL_RC_OK) {
  probe_clip_fail(p,"file_contents_request");
  return;
 }
 printf("file_contents_request lindex=%u offset=%llu len=%u\n",(unsigned)index,
  (unsigned long long)offset,(unsigned)length);
 fflush(stdout);
}
static UINT probe_clip_rdr_server_capabilities(CliprdrClientContext *cliprdr,
                                               const CLIPRDR_CAPABILITIES *capabilities) {
 UINT32 general_flags=0;
 (void)cliprdr;
 if (capabilities && capabilities->capabilitySets && capabilities->cCapabilitiesSets>0)
  general_flags=((const CLIPRDR_GENERAL_CAPABILITY_SET *)capabilities->capabilitySets)->generalFlags;
 printf("caps_received general_flags=0x%08x\n",(unsigned)general_flags);
 fflush(stdout);
 return CHANNEL_RC_OK;
}
static UINT probe_clip_rdr_monitor_ready(CliprdrClientContext *cliprdr,
                                         const CLIPRDR_MONITOR_READY *monitor_ready) {
 probe_context *p=probe_clip_from(cliprdr);
 (void)monitor_ready;
 if (!p) return CHANNEL_RC_OK;
 pthread_mutex_lock(&p->clip_mutex);
 p->clip_monitor_ready=TRUE;
 p->clip_stage="format_list";
 pthread_mutex_unlock(&p->clip_mutex);
 (void)probe_clip_send_caps(p);
 if (p->mode!=11) return CHANNEL_RC_OK;
 /* Default: the standard fixed file ids (0xC003/0xC004) plus long names.
  * RDP_PROBE_DYNAMIC_FORMAT_IDS=1: reproduce mstsc.exe's registered-format
  * advertisement exactly (dynamic ids + names, no fixed file ids), so the
  * worker's CB_FORMAT_DATA_REQUEST must carry the advertised descriptor id. */
 CLIPRDR_FORMAT formats[4]={{0}};
 CLIPRDR_FORMAT_LIST list={0};
 UINT32 format_count=2;
 if (p->clip_dynamic_format_ids) {
  formats[0].formatId=49319; /* Preferred DropEffect */
  formats[0].formatName=(char *)"Preferred DropEffect";
  formats[1].formatId=p->clip_contents_format_id;
  formats[1].formatName=(char *)"FileContents";
  formats[2].formatId=p->clip_descriptor_format_id;
  formats[2].formatName=(char *)"FileGroupDescriptorW";
  formats[3].formatId=49337; /* ZoneIdentifier */
  formats[3].formatName=(char *)"ZoneIdentifier";
  format_count=4;
 } else {
  formats[0].formatId=0xC003; /* FileGroupDescriptorW */
  formats[0].formatName=(char *)"FileGroupDescriptorW";
  formats[1].formatId=0xC004; /* FileContents */
  formats[1].formatName=(char *)"FileContents";
 }
 list.common.msgType=CB_FORMAT_LIST;
 list.numFormats=format_count;
 list.formats=formats;
 if (!p->cliprdr || !p->cliprdr->ClientFormatList ||
     p->cliprdr->ClientFormatList(p->cliprdr,&list)!=CHANNEL_RC_OK) {
  probe_clip_fail(p,"format_list");
  return CHANNEL_RC_OK;
 }
 pthread_mutex_lock(&p->clip_mutex);
 p->clip_format_list_sent=TRUE;p->clip_stage="descriptor_request";
 pthread_mutex_unlock(&p->clip_mutex);
 if (p->clip_dynamic_format_ids) {
  printf("format_list_sent formats=%u files=%u dynamic_ids=1 descriptor_id=%u contents_id=%u\n",
         (unsigned)format_count,(unsigned)p->clip_offer_count,
         (unsigned)p->clip_descriptor_format_id,(unsigned)p->clip_contents_format_id);
 } else {
  printf("format_list_sent formats=%u files=%u\n",(unsigned)format_count,
         (unsigned)p->clip_offer_count);
 }
 fflush(stdout);
 return CHANNEL_RC_OK;
}
static UINT probe_clip_rdr_server_format_list(CliprdrClientContext *cliprdr,
                                              const CLIPRDR_FORMAT_LIST *formats) {
 probe_context *p=probe_clip_from(cliprdr);
 if (!p || !formats) return CHANNEL_RC_OK;
 BOOL files=FALSE;
 for (UINT32 i=0;i<formats->numFormats;i++)
  if (formats->formats && formats->formats[i].formatId==0xC003) files=TRUE;
 /* MS-RDPECLIP: a format list is always answered, even when it is ignored. */
 CLIPRDR_FORMAT_LIST_RESPONSE response={0};
 response.common.msgType=CB_FORMAT_LIST_RESPONSE;
 response.common.msgFlags=CB_RESPONSE_OK;
 if (cliprdr->ClientFormatListResponse)
  (void)cliprdr->ClientFormatListResponse(cliprdr,&response);
 if (p->mode!=12 || !files) return CHANNEL_RC_OK;
 pthread_mutex_lock(&p->clip_mutex);
 BOOL already=p->clip_format_list_sent;
 if (!already) {p->clip_format_list_sent=TRUE;p->clip_stage="descriptor";}
 pthread_mutex_unlock(&p->clip_mutex);
 if (already) return CHANNEL_RC_OK;
 printf("format_list_received formats=%u file_formats=1\n",(unsigned)formats->numFormats);
 fflush(stdout);
 CLIPRDR_FORMAT_DATA_REQUEST request={0};
 request.common.msgType=CB_FORMAT_DATA_REQUEST;
 request.requestedFormatId=0xC003;
 if (!p->cliprdr || !p->cliprdr->ClientFormatDataRequest ||
     p->cliprdr->ClientFormatDataRequest(p->cliprdr,&request)!=CHANNEL_RC_OK) {
  probe_clip_fail(p,"descriptor_request");
  return CHANNEL_RC_OK;
 }
 puts("descriptor_request_sent");
 fflush(stdout);
 return CHANNEL_RC_OK;
}
static UINT probe_clip_rdr_server_format_list_response(
 CliprdrClientContext *cliprdr,const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
 (void)cliprdr;
 if (!response) return CHANNEL_RC_OK;
 printf("format_list_response ok=%u\n",
  (unsigned)((response->common.msgFlags&CB_RESPONSE_OK)!=0));
 fflush(stdout);
 return CHANNEL_RC_OK;
}
static UINT probe_clip_rdr_server_data_request(CliprdrClientContext *cliprdr,
                                               const CLIPRDR_FORMAT_DATA_REQUEST *request) {
 probe_context *p=probe_clip_from(cliprdr);
 if (!p || !request) return CHANNEL_RC_OK;
 if (p->mode!=11 || request->requestedFormatId!=p->clip_descriptor_format_id ||
     !p->clip_offer_list) {
  /* Like mstsc: a request for a format id this client did not advertise (for
   * example the fixed 0xC003 in dynamic-id mode) is answered with FAIL. */
  CLIPRDR_FORMAT_DATA_RESPONSE failed={0};
  failed.common.msgType=CB_FORMAT_DATA_RESPONSE;
  failed.common.msgFlags=CB_RESPONSE_FAIL;
  if (p->cliprdr && p->cliprdr->ClientFormatDataResponse)
   (void)p->cliprdr->ClientFormatDataResponse(p->cliprdr,&failed);
  return CHANNEL_RC_OK;
 }
 printf("descriptor_requested format=0x%08x\n",(unsigned)request->requestedFormatId);
 fflush(stdout);
 CLIPRDR_FORMAT_DATA_RESPONSE response={0};
 response.common.msgType=CB_FORMAT_DATA_RESPONSE;
 response.common.msgFlags=CB_RESPONSE_OK;
 response.common.dataLen=p->clip_offer_list_len;
 response.requestedFormatData=p->clip_offer_list;
 if (p->cliprdr->ClientFormatDataResponse(p->cliprdr,&response)!=CHANNEL_RC_OK) {
  probe_clip_fail(p,"descriptor_response");
  return CHANNEL_RC_OK;
 }
 printf("descriptor_sent bytes=%u\n",(unsigned)p->clip_offer_list_len);
 fflush(stdout);
 pthread_mutex_lock(&p->clip_mutex);
 p->clip_descriptor_sent=TRUE;p->clip_stage="contents";
 BOOL empty=p->clip_offer_bytes==0;
 if (empty) {p->clip_done=TRUE;p->clip_done_at=GetTickCount64();p->clip_stage="done";}
 pthread_mutex_unlock(&p->clip_mutex);
 return CHANNEL_RC_OK;
}
static UINT probe_clip_rdr_server_format_data_response(
 CliprdrClientContext *cliprdr,const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
 probe_context *p=probe_clip_from(cliprdr);
 if (!p || !response || p->mode!=12) return CHANNEL_RC_OK;
 if (!(response->common.msgFlags&CB_RESPONSE_OK) || !response->requestedFormatData ||
     response->common.dataLen<4) {
  probe_clip_fail(p,"descriptor_response");
  return CHANNEL_RC_OK;
 }
 FILEDESCRIPTORW *descriptors=NULL;
 UINT32 count=0;
 UINT rc=cliprdr_parse_file_list(response->requestedFormatData,response->common.dataLen,
  &descriptors,&count);
 if (rc!=CHANNEL_RC_OK || !descriptors || count==0) {
  fprintf(stderr,"event=probe_clip_descriptor_parse_failed result=%u files=%u\n",rc,count);
  free(descriptors);
  probe_clip_fail(p,"descriptor_parse");
  return CHANNEL_RC_OK;
 }
 if (count>PROBE_CLIP_RX_MAX_FILES) {
  free(descriptors);
  probe_clip_fail(p,"too_many_files");
  return CHANNEL_RC_OK;
 }
 p->clip_rx=calloc(count,sizeof(probe_clip_rx_file));
 if (!p->clip_rx) {free(descriptors);probe_clip_fail(p,"out_of_memory");return CHANNEL_RC_OK;}
 p->clip_rx_count=count;
 for (UINT32 i=0;i<count;i++) {
  probe_clip_rx_file *file=&p->clip_rx[i];
  file->size=((UINT64)descriptors[i].nFileSizeHigh<<32)|(UINT64)descriptors[i].nFileSizeLow;
  (void)ConvertWCharToUtf8(descriptors[i].cFileName,file->name,sizeof(file->name));
  if (file->size>PROBE_CLIP_RX_MAX_BYTES) {
   free(descriptors);
   probe_clip_fail(p,"file_too_large");
   return CHANNEL_RC_OK;
  }
  file->data=malloc((size_t)(file->size ? file->size : 1));
  if (!file->data) {free(descriptors);probe_clip_fail(p,"out_of_memory");return CHANNEL_RC_OK;}
  printf("file_entry lindex=%u size=%llu name=%s\n",(unsigned)i,
   (unsigned long long)file->size,file->name);
 }
 free(descriptors);
 printf("descriptor_received files=%u\n",(unsigned)count);
 fflush(stdout);
 probe_clip_set_stage(p,"contents");
 probe_clip_request_size(p,0);
 return CHANNEL_RC_OK;
}
static void probe_clip_send_file_contents(probe_context *p,const CLIPRDR_FILE_CONTENTS_REQUEST *request,
                                          UINT16 msg_flags,UINT32 length,const BYTE *data) {
 CLIPRDR_FILE_CONTENTS_RESPONSE response={0};
 response.common.msgType=CB_FILECONTENTS_RESPONSE;
 response.common.msgFlags=msg_flags;
 response.streamId=request->streamId;
 response.cbRequested=length;
 response.requestedData=data;
 if (p->cliprdr && p->cliprdr->ClientFileContentsResponse)
  (void)p->cliprdr->ClientFileContentsResponse(p->cliprdr,&response);
}
static UINT probe_clip_rdr_server_file_contents_request(
 CliprdrClientContext *cliprdr,const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
 probe_context *p=probe_clip_from(cliprdr);
 if (!p || !request || p->mode!=11) return CHANNEL_RC_OK;
 UINT64 offset=((UINT64)request->nPositionHigh<<32)|(UINT64)request->nPositionLow;
 printf("file_contents_request lindex=%u offset=%llu len=%u\n",(unsigned)request->listIndex,
  (unsigned long long)offset,(unsigned)request->cbRequested);
 fflush(stdout);
 if (request->listIndex>=p->clip_offer_count) {
  probe_clip_send_file_contents(p,request,CB_RESPONSE_FAIL,0,NULL);
  return CHANNEL_RC_OK;
 }
 probe_clip_offer_file *file=&p->clip_offer[request->listIndex];
 if (request->dwFlags&FILECONTENTS_SIZE) {
  UINT64 size=file->size;
  BYTE size_data[8];
  for (int i=0;i<8;i++) size_data[i]=(BYTE)((size>>(8*i))&0xFFu);
  probe_clip_send_file_contents(p,request,CB_RESPONSE_OK,8,size_data);
  printf("file_size_sent lindex=%u size=%llu\n",(unsigned)request->listIndex,
   (unsigned long long)size);
  fflush(stdout);
  return CHANNEL_RC_OK;
 }
 if (!(request->dwFlags&FILECONTENTS_RANGE)) {
  probe_clip_send_file_contents(p,request,CB_RESPONSE_FAIL,0,NULL);
  return CHANNEL_RC_OK;
 }
 UINT32 length=request->cbRequested;
 if (offset>file->size) length=0;
 else if (offset+(UINT64)length>file->size) length=(UINT32)(file->size-offset);
 const BYTE *data=(length && file->content) ? file->content+offset : NULL;
 /* Error-path injection: break the FILECONTENTS contract on purpose so the
  * worker's remote->local abort path (clipboard_file_rejected reason=
  * client_failed + IPC 15 status=2) can be exercised. */
 if (p->clip_fail_contents && !p->clip_fail_injected) {
  p->clip_fail_injected=TRUE;
  if (p->clip_fail_contents==1) {
   probe_clip_send_file_contents(p,request,CB_RESPONSE_FAIL,0,NULL);
   printf("fail_injection kind=response_fail lindex=%u offset=%llu len=%u\n",
    (unsigned)request->listIndex,(unsigned long long)offset,(unsigned)length);
   fflush(stdout);
   probe_clip_fail(p,"injected_response_fail");
  } else {
   UINT32 sent=(length>1) ? length/2 : 0;
   probe_clip_send_file_contents(p,request,CB_RESPONSE_OK,sent,sent?data:NULL);
   printf("fail_injection kind=short_response lindex=%u offset=%llu len=%u sent=%u\n",
    (unsigned)request->listIndex,(unsigned long long)offset,(unsigned)length,(unsigned)sent);
   fflush(stdout);
   probe_clip_fail(p,"injected_short_response");
  }
  return CHANNEL_RC_OK;
 }
 probe_clip_send_file_contents(p,request,CB_RESPONSE_OK,length,data);
 if (length) {
  pthread_mutex_lock(&p->clip_mutex);
  UINT64 end=offset+(UINT64)length;
  if (end>p->clip_offer_served[request->listIndex]) p->clip_offer_served[request->listIndex]=end;
  p->clip_bytes+=length;
  BOOL complete=TRUE;
  for (UINT32 i=0;i<p->clip_offer_count;i++)
   if (p->clip_offer_served[i]<p->clip_offer[i].size) complete=FALSE;
  if (complete) {p->clip_done=TRUE;p->clip_done_at=GetTickCount64();p->clip_stage="done";}
  pthread_mutex_unlock(&p->clip_mutex);
  printf("file_contents_sent bytes=%u\n",(unsigned)length);
  fflush(stdout);
 }
 return CHANNEL_RC_OK;
}
static UINT probe_clip_rdr_server_file_contents_response(
 CliprdrClientContext *cliprdr,const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
 probe_context *p=probe_clip_from(cliprdr);
 if (!p || !response || p->mode!=12) return CHANNEL_RC_OK;
 UINT32 index=p->clip_rx_index;
 UINT32 kind=p->clip_rx_kind;
 if (index>=p->clip_rx_count) return CHANNEL_RC_OK;
 probe_clip_rx_file *file=&p->clip_rx[index];
 if (response->streamId!=p->clip_rx_stream) {probe_clip_fail(p,"bad_stream_id");return CHANNEL_RC_OK;}
 if (!(response->common.msgFlags&CB_RESPONSE_OK)) {probe_clip_fail(p,"contents_failed");return CHANNEL_RC_OK;}
 if (kind==1) {
  if (!response->requestedData || response->cbRequested!=8) {
   probe_clip_fail(p,"bad_size_response");
   return CHANNEL_RC_OK;
  }
  UINT64 size=0;
  for (int i=0;i<8;i++) size|=(UINT64)response->requestedData[i]<<(8*i);
  if (size!=file->size) {
   printf("file_size_mismatch lindex=%u expected=%llu got=%llu\n",(unsigned)index,
    (unsigned long long)file->size,(unsigned long long)size);
   fflush(stdout);
   probe_clip_fail(p,"size_mismatch");
   return CHANNEL_RC_OK;
  }
  printf("file_size_ok lindex=%u size=%llu\n",(unsigned)index,(unsigned long long)size);
  fflush(stdout);
  p->clip_rx_offset=0;
  if (size==0) {
   BYTE digest[32];
   char hex[65];
   probe_clip_sha256(NULL,0,digest);
   probe_clip_hex(digest,32,hex);
   const char *expected=(p->clip_sha_expected && index<p->clip_expected_count)
    ? p->clip_expected_sha[index] : NULL;
   if (expected && strcasecmp(expected,hex)!=0) {
    printf("file_contents_mismatch lindex=%u expected=%s got=%s\n",(unsigned)index,expected,hex);
    fflush(stdout);probe_clip_fail(p,"sha256_mismatch");return CHANNEL_RC_OK;
   }
   printf("file_contents_ok lindex=%u bytes=0 sha256=%s\n",(unsigned)index,hex);
   fflush(stdout);
   UINT32 next=index+1;
   if (next<p->clip_rx_count) probe_clip_request_size(p,next);
   else probe_clip_mark_done(p);
   return CHANNEL_RC_OK;
  }
  probe_clip_request_range(p);
  return CHANNEL_RC_OK;
 }
 if (kind!=2) {probe_clip_fail(p,"unexpected_response");return CHANNEL_RC_OK;}
 UINT32 length=response->cbRequested;
 UINT64 offset=p->clip_rx_offset;
 if (length==0 || length>p->clip_rx_request_len || offset+(UINT64)length>file->size ||
     (!response->requestedData && length>0)) {
  probe_clip_fail(p,"bad_range");
  return CHANNEL_RC_OK;
 }
 memcpy(file->data+offset,response->requestedData,length);
 p->clip_rx_offset=offset+(UINT64)length;
 file->received=p->clip_rx_offset;
 printf("file_contents_received lindex=%u offset=%llu bytes=%u\n",(unsigned)index,
  (unsigned long long)offset,(unsigned)length);
 fflush(stdout);
 /* Overlong-range mode expects the server to clamp the final request to EOF and
  * answer fewer bytes than requested (mstsc paste sequence). */
 if (length<p->clip_rx_request_len) {
  printf("file_contents_short_response lindex=%u requested=%u got=%u\n",(unsigned)index,
   (unsigned)p->clip_rx_request_len,(unsigned)length);
  fflush(stdout);
 }
 if (p->clip_rx_offset>=file->size) {
  BYTE digest[32];
  char hex[65];
  probe_clip_sha256(file->data,(size_t)file->size,digest);
  probe_clip_hex(digest,32,hex);
  const char *expected=(p->clip_sha_expected && index<p->clip_expected_count)
   ? p->clip_expected_sha[index] : NULL;
  if (expected && strcasecmp(expected,hex)!=0) {
   printf("file_contents_mismatch lindex=%u expected=%s got=%s\n",(unsigned)index,expected,hex);
   fflush(stdout);probe_clip_fail(p,"sha256_mismatch");return CHANNEL_RC_OK;
  }
  printf("file_contents_ok lindex=%u bytes=%llu sha256=%s\n",(unsigned)index,
   (unsigned long long)file->size,hex);
  fflush(stdout);
  pthread_mutex_lock(&p->clip_mutex);
  p->clip_bytes+=(UINT32)file->size;
  pthread_mutex_unlock(&p->clip_mutex);
  UINT32 next=index+1;
  if (next<p->clip_rx_count) probe_clip_request_size(p,next);
  else probe_clip_mark_done(p);
  return CHANNEL_RC_OK;
 }
 probe_clip_request_range(p);
 return CHANNEL_RC_OK;
}
static BOOL probe_clip_valid_sha(const char *text) {
 if (!text || strlen(text)!=64) return FALSE;
 for (size_t i=0;i<64;i++) if (!isxdigit((unsigned char)text[i])) return FALSE;
 return TRUE;
}
/* Build the in-probe file offer (mode 11) or the expected-sha list (mode 12).
 * Called once from rdp_probe before the connection sequence. */
static BOOL probe_clip_init(probe_context *p) {
 pthread_mutex_init(&p->clip_mutex,NULL);
 p->clip_mutex_init=TRUE;
 p->clip_timeout_ms=probe_env_uint("RDP_PROBE_CLIP_TIMEOUT_MS",PROBE_CLIP_TIMEOUT_DEFAULT,1000,120000);
 /* mstsc pastes with one full 256 KiB range per request, including the last one
  * (field evidence 2026-11-08); opt in so the loopback covers the short tail. */
 p->clip_overlong_range=probe_env_flag("RDP_PROBE_OVERLONG_RANGE");
 p->clip_chunk=probe_env_uint("RDP_PROBE_CLIP_CHUNK",
  p->clip_overlong_range ? 262144u : 65536u,1024,1048576);
 /* Deliberate client-side failure injection for the worker error-path tests:
  * 1 = answer the first FILECONTENTS_RANGE with CB_RESPONSE_FAIL,
  * 2 = answer it with half of the requested bytes. */
 const char *fail_contents=getenv("RDP_PROBE_FAIL_CONTENTS");
 if (fail_contents && strcmp(fail_contents,"response_fail")==0) p->clip_fail_contents=1;
 else if (fail_contents && (strcmp(fail_contents,"short_response")==0 ||
                            strcmp(fail_contents,"size_mismatch")==0))
  p->clip_fail_contents=2;
 else if (fail_contents && fail_contents[0] && strcmp(fail_contents,"none")!=0)
  fprintf(stderr,"event=probe_clip_unknown_fail_contents value=%s\n",fail_contents);
 p->clip_unsafe_name=probe_env_flag("RDP_PROBE_CLIP_UNSAFE_NAME");
 /* Fixed mstsc/FreeRDP format ids by default: the default mode-11 wire bytes
  * and stdout lines stay identical to the pre-dynamic-id probe. */
 p->clip_descriptor_format_id=0xC003u;
 p->clip_contents_format_id=0xC004u;
 p->clip_stage="channel";
 if (p->mode!=11) {
  const char *sha=getenv("RDP_PROBE_FILE_SHA256");
  if (!sha || !sha[0]) return TRUE;
  char *copy=strdup(sha);
  if (!copy) return FALSE;
  p->clip_expected_sha=calloc(PROBE_CLIP_RX_MAX_FILES,sizeof(char *));
  if (!p->clip_expected_sha) {free(copy);return FALSE;}
  char *save=NULL;
  char *token=strtok_r(copy,",",&save);
  while (token && p->clip_expected_count<PROBE_CLIP_RX_MAX_FILES) {
   if (!probe_clip_valid_sha(token)) {
    fprintf(stderr,"event=probe_clip_bad_sha index=%u\n",(unsigned)p->clip_expected_count);
    free(copy);
    return FALSE;
   }
   p->clip_expected_sha[p->clip_expected_count++]=strdup(token);
   token=strtok_r(NULL,",",&save);
  }
  free(copy);
  p->clip_sha_expected=p->clip_expected_count>0;
  return TRUE;
 }
 /* Mode 11: opt-in mstsc-style dynamic format ids + long names. The standard
  * fixed ids above only stay the default so the existing loopback tests keep
  * their exact wire bytes; real Windows clients use the dynamic ids. */
 p->clip_dynamic_format_ids=probe_env_flag("RDP_PROBE_DYNAMIC_FORMAT_IDS");
 if (p->clip_dynamic_format_ids) {
  p->clip_descriptor_format_id=49314u; /* 0xC0A2 FileGroupDescriptorW (mstsc) */
  p->clip_contents_format_id=49269u;   /* 0xC075 FileContents (mstsc) */
  fprintf(stderr,"event=probe_clip_dynamic_format_ids descriptor=%u contents=%u\n",
          (unsigned)p->clip_descriptor_format_id,(unsigned)p->clip_contents_format_id);
  fflush(stderr);
 }
 UINT32 count=probe_env_uint("RDP_PROBE_FILE_COUNT",1,1,PROBE_CLIP_FILE_MAX);
 UINT32 default_size=probe_env_uint("RDP_PROBE_FILE_SIZE",1024,0,32u*1024u*1024u);
 UINT32 sizes[PROBE_CLIP_FILE_MAX];
 const char *names[PROBE_CLIP_FILE_MAX]={
  probe_env_string_exact("RDP_PROBE_FILE_NAME","probe-file.bin"),
  probe_env_string_exact("RDP_PROBE_FILE_NAME2","probe-file-2.bin"),
  probe_env_string_exact("RDP_PROBE_FILE_NAME3","probe-file-3.bin")};
 sizes[0]=default_size;
 sizes[1]=probe_env_uint("RDP_PROBE_FILE_SIZE2",default_size,0,32u*1024u*1024u);
 sizes[2]=probe_env_uint("RDP_PROBE_FILE_SIZE3",default_size,0,32u*1024u*1024u);
 p->clip_offer=calloc(count,sizeof(probe_clip_offer_file));
 p->clip_offer_served=calloc(count,sizeof(UINT64));
 p->clip_offer_desc=calloc(count,sizeof(FILEDESCRIPTORW));
 if (!p->clip_offer || !p->clip_offer_served || !p->clip_offer_desc) return FALSE;
 p->clip_offer_count=count;
 for (UINT32 i=0;i<count;i++) {
  probe_clip_offer_file *file=&p->clip_offer[i];
  const char *name=names[i];
  const size_t name_length=strlen(name);
  if (name_length>=PROBE_CLIP_FILE_NAME_MAX && !p->clip_unsafe_name) {
   fprintf(stderr,"event=probe_clip_name_too_long index=%u\n",(unsigned)i);
   return FALSE;
  }
  /* Keep a copy only when it fits; the descriptor conversion below uses the
   * env string directly so over-long unsafe names still reach the wire. */
  if (name_length<sizeof(file->name)) {
   memcpy(file->name,name,name_length);
   file->name[name_length]='\0';
  }
  file->size=(UINT64)sizes[i];
  file->content=malloc((size_t)(file->size ? file->size : 1));
  if (!file->content) return FALSE;
  for (UINT64 j=0;j<file->size;j++)
   file->content[j]=(BYTE)((j*31u+(UINT64)i*97u+13u)&0xFFu);
  FILEDESCRIPTORW *descriptor=&p->clip_offer_desc[i];
  descriptor->dwFlags=FD_ATTRIBUTES|FD_FILESIZE|FD_WRITESTIME;
  descriptor->dwFileAttributes=0x80; /* FILE_ATTRIBUTE_NORMAL */
  descriptor->ftLastWriteTime.dwLowDateTime=0x12345678u;
  descriptor->ftLastWriteTime.dwHighDateTime=0x01D9A000u;
  descriptor->nFileSizeHigh=(DWORD)(file->size>>32);
  descriptor->nFileSizeLow=(DWORD)(file->size&0xFFFFFFFFu);
  {
   const SSIZE_T wide_length=ConvertUtf8ToWChar(name,descriptor->cFileName,
    sizeof(descriptor->cFileName)/sizeof(descriptor->cFileName[0]));
   if (wide_length<0) descriptor->cFileName[0]=0;
  }
  descriptor->cFileName[sizeof(descriptor->cFileName)/sizeof(descriptor->cFileName[0])-1]=0;
  p->clip_offer_bytes+=(UINT32)file->size;
 }
 if (cliprdr_serialize_file_list(p->clip_offer_desc,count,&p->clip_offer_list,
                                 &p->clip_offer_list_len)!=CHANNEL_RC_OK) {
  fprintf(stderr,"event=probe_clip_serialize_failed\n");
  return FALSE;
 }
 return TRUE;
}
static void probe_clip_free(probe_context *p) {
 if (!p) return;
 if (p->clip_offer) {
  for (UINT32 i=0;i<p->clip_offer_count;i++) free(p->clip_offer[i].content);
  free(p->clip_offer);
  p->clip_offer=NULL;
 }
 free(p->clip_offer_served);p->clip_offer_served=NULL;
 free(p->clip_offer_desc);p->clip_offer_desc=NULL;
 free(p->clip_offer_list);p->clip_offer_list=NULL;
 if (p->clip_rx) {
  for (UINT32 i=0;i<p->clip_rx_count;i++) free(p->clip_rx[i].data);
  free(p->clip_rx);
  p->clip_rx=NULL;
 }
 free(p->clip_rx_descriptor);p->clip_rx_descriptor=NULL;
 if (p->clip_expected_sha) {
  for (UINT32 i=0;i<p->clip_expected_count;i++) free(p->clip_expected_sha[i]);
  free(p->clip_expected_sha);
  p->clip_expected_sha=NULL;
 }
 if (p->clip_mutex_init) {pthread_mutex_destroy(&p->clip_mutex);p->clip_mutex_init=FALSE;}
}

/* Print the client framebuffer pixels at the requested probe points. The gdi
 * buffer uses PIXEL_FORMAT_XRGB32, whose naming is byte-position based
 * (X, R, G, B in memory), so blue is the high byte. */
static void probe_sample_pixels(probe_context *p) {
 const char *points=getenv("RDP_PROBE_SAMPLE_POINTS");
 if (!points || !points[0] || !p->context.gdi || !p->context.gdi->primary_buffer) return;
 rdpGdi *gdi=p->context.gdi;
 char *copy=strdup(points);
 if (!copy) return;
 char *token=strtok(copy,",");
 unsigned count=0;
 while (token && count<32) {
  unsigned x=0,y=0;
  if (sscanf(token,"%u:%u",&x,&y)==2) {
   BYTE b=0,g=0,r=0,a=0;
   if (x<gdi->width && y<gdi->height) {
    const BYTE *pixel=gdi->primary_buffer+(size_t)y*gdi->stride+(size_t)x*4;
    a=pixel[0];r=pixel[1];g=pixel[2];b=pixel[3];
   }
   printf("sample x=%u y=%u bgra=%u,%u,%u,%u\n",x,y,(unsigned)b,(unsigned)g,(unsigned)r,(unsigned)a);
  }
  count++;
  token=strtok(NULL,",");
 }
 free(copy);
 fflush(stdout);
}

/* Client-side resolution change callback (deactivate/reactivate path). */
static BOOL probe_desktop_resize(rdpContext *context) {
 probe_context *p=(probe_context *)context;
 UINT32 width=freerdp_settings_get_uint32(context->settings,FreeRDP_DesktopWidth);
 UINT32 height=freerdp_settings_get_uint32(context->settings,FreeRDP_DesktopHeight);
 if (!width || !height) {
  if (context->gdi) {width=context->gdi->width;height=context->gdi->height;}
 }
 if (!width || !height) return FALSE;
 rdpGdi *gdi=context->gdi;
 if (gdi && (gdi->width!=width || gdi->height!=height)) {
  if (!gdi_resize(gdi,width,height)) return FALSE;
  if (gdi->width!=width || gdi->height!=height) return FALSE;
 }
 p->width=width;p->height=height;
 p->reactivated=TRUE;p->reactivated_width=width;p->reactivated_height=height;
 p->reactivation_count++;
 /* Baseline the received-rectangle counter at the reactivation itself, so a
  * frame that arrives after it is what satisfies the resize conditions (frames
  * from before the reactivation are already ordered before it). */
 if (p->reactivation_count==1) p->bitmap_rectangles_at_resize=p->bitmap_rectangles;
 else if (p->reactivation_count==2) p->bitmap_rectangles_at_resize2=p->bitmap_rectangles;
 printf("reactivated width=%u height=%u count=%u\n",width,height,p->reactivation_count);
 fflush(stdout);
 return TRUE;
}

/* Installed before the connection sequence so a resolution change during the
 * handshake never reaches FreeRDP's default (client-side) DesktopResize sender. */
static BOOL probe_pre_connect(freerdp *instance) {
 if (!instance || !instance->context || !instance->context->update) return FALSE;
 instance->context->update->DesktopResize=probe_desktop_resize;
 return TRUE;
}

static void probe_channel_connected(void *context,const ChannelConnectedEventArgs *event) {
 probe_context *p=(probe_context *)context;
 if (!p || !event || !event->name) return;
 if (strcmp(event->name,DISP_DVC_CHANNEL_NAME)==0) {
  p->disp=(DispClientContext *)event->pInterface;
  fprintf(stderr,"event=probe_disp_channel_connected interface=%u\n",p->disp!=NULL ? 1u : 0u);
 }
 if (strcmp(event->name,CLIPRDR_SVC_CHANNEL_NAME)==0) {
  p->cliprdr=(CliprdrClientContext *)event->pInterface;
  if (p->cliprdr) {
   p->cliprdr->custom=p;
   p->cliprdr->ServerCapabilities=probe_clip_rdr_server_capabilities;
   p->cliprdr->MonitorReady=probe_clip_rdr_monitor_ready;
   p->cliprdr->ServerFormatList=probe_clip_rdr_server_format_list;
   p->cliprdr->ServerFormatListResponse=probe_clip_rdr_server_format_list_response;
   p->cliprdr->ServerFormatDataRequest=probe_clip_rdr_server_data_request;
   p->cliprdr->ServerFormatDataResponse=probe_clip_rdr_server_format_data_response;
   p->cliprdr->ServerFileContentsRequest=probe_clip_rdr_server_file_contents_request;
   p->cliprdr->ServerFileContentsResponse=probe_clip_rdr_server_file_contents_response;
   probe_clip_set_stage(p,"monitor_ready");
   fprintf(stderr,"event=probe_cliprdr_channel_connected interface=1\n");
   puts("cliprdr_channel_connected");
   fflush(stdout);
  }
 }
}

static BOOL probe_connect(freerdp *instance) {
 if (!gdi_init(instance,PIXEL_FORMAT_XRGB32)) return FALSE;
 probe_context *p=(probe_context *)instance->context;
 p->bitmap_update=instance->context->update->BitmapUpdate;
  p->surface_bits=instance->context->update->SurfaceBits;
  instance->context->update->BitmapUpdate=probe_bitmap_update;
  instance->context->update->SurfaceBits=probe_surface_bits;
 instance->context->update->EndPaint=probe_paint;
 /* The negotiated desktop size reaches the client through the server's Demand
  * Active; gdi_init has already sized the framebuffer from it, so report that
  * size as the session desktop. */
 if (instance->context->gdi) {
  p->width=instance->context->gdi->width;p->height=instance->context->gdi->height;
 }
 if (p->width!=p->requested_width || p->height!=p->requested_height) {
  printf("reactivated width=%u height=%u\n",p->width,p->height);
  fflush(stdout);
 }
 if ((p->mode==10 || p->mode==11 || p->mode==12) && instance->context->pubSub) {
  (void)PubSub_SubscribeChannelConnected(instance->context->pubSub,probe_channel_connected);
 }
 return TRUE;
}
int rdp_probe(const char *address,int port,const char *user,const char *domain,const char *password,int mode,int width,int height) {
 if (width<1 || height<1 || width>16384 || height>16384) return 10;
 if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 10;
 freerdp *instance=freerdp_new();
 if (!instance) return 10;
 instance->ContextSize=sizeof(probe_context);instance->PostConnect=probe_connect;
 instance->PreConnect=probe_pre_connect;
 if (!freerdp_context_new(instance)) {freerdp_free(instance);return 10;}
 rdpSettings *s=instance->context->settings;
 BOOL ok=freerdp_settings_set_string(s,FreeRDP_ServerHostname,address) &&
  freerdp_settings_set_uint32(s,FreeRDP_ServerPort,(UINT32)port) &&
  freerdp_settings_set_string(s,FreeRDP_Username,user) &&
  freerdp_settings_set_string(s,FreeRDP_Domain,domain) &&
  freerdp_settings_set_string(s,FreeRDP_Password,password) &&
  freerdp_settings_set_bool(s,FreeRDP_IgnoreCertificate,TRUE) && /* loopback test only */
  freerdp_settings_set_bool(s,FreeRDP_NlaSecurity,mode!=2) &&
   freerdp_settings_set_bool(s,FreeRDP_RdpSecurity,FALSE) &&
   freerdp_settings_set_bool(s,FreeRDP_TlsSecurity,mode==2) &&
   freerdp_settings_set_bool(s,FreeRDP_ExtSecurity,mode!=2) &&
   freerdp_settings_set_bool(s,FreeRDP_SupportGraphicsPipeline,mode==8) &&
   freerdp_settings_set_bool(s,FreeRDP_GfxH264,mode==8) &&
   freerdp_settings_set_bool(s,FreeRDP_NoBitmapCompressionHeader,mode==5) &&
    freerdp_settings_set_bool(s,FreeRDP_SupportDisplayControl,mode==10) &&
    freerdp_settings_set_bool(s,FreeRDP_NSCodec,mode==5 || mode==7) &&
     freerdp_settings_set_uint32(s,FreeRDP_DesktopWidth,(UINT32)width) &&
   freerdp_settings_set_uint32(s,FreeRDP_DesktopHeight,(UINT32)height) &&
  freerdp_settings_set_uint32(s,FreeRDP_ColorDepth,32) &&
  freerdp_settings_set_uint32(s,FreeRDP_TcpConnectTimeout,3000);
  int result=11;
  probe_context *ctx=(probe_context *)instance->context;
  ctx->width=(UINT32)width;ctx->height=(UINT32)height;ctx->gfx_mode=(mode==8);
  ctx->mode=mode;ctx->requested_width=(UINT32)width;ctx->requested_height=(UINT32)height;
  if (mode==11 || mode==12) {
   if (!probe_clip_init(ctx)) {
    fprintf(stderr,"event=probe_clip_init_failed mode=%d\n",mode);
    printf("file_paste_failed reason=init_failed stage=%s mode=%d\n",
     ctx->clip_stage ? ctx->clip_stage : "init",mode);
    fflush(stdout);
    result=22;ok=FALSE;
   }
  }
 if (ok && (mode==8 || mode==10 || mode==11 || mode==12) &&
     freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry,0)!=0) {
  fprintf(stderr,"event=gfx_probe_provider_registration_failed\n");ok=FALSE;
 }
 if (ok && (mode==8 || mode==10 || mode==11 || mode==12)) instance->LoadChannels=freerdp_client_load_channels;
 if (ok && freerdp_connect(instance)) {
  UINT64 bench_seconds=10;
  if (mode==9) {
   const char *bench_setting=getenv("RDP_PROBE_BENCH_SECONDS");
   if (bench_setting) {
    long value=strtol(bench_setting,NULL,10);
    if (value>=1 && value<=120) bench_seconds=(UINT64)value;
   }
  }
  /* Optional mode-9 hook: request one client RefreshRect after N ms so tests
   * can verify that a refresh forces a full frame and the following delta frame
   * returns to incremental delivery. */
  UINT64 refresh_at_ms=0;
  if (mode==9) {
   const char *refresh_setting=getenv("RDP_PROBE_REFRESH_AT_MS");
   if (refresh_setting) {
    long value=strtol(refresh_setting,NULL,10);
    if (value>=0 && value<=120000) refresh_at_ms=(UINT64)value;
   }
  }
  /* Mode 10: client-driven resize parameters. */
  UINT64 resize_at_ms=0;
  if (mode==10) {
   resize_at_ms=probe_env_uint("RDP_PROBE_RESIZE_AT_MS",500,0,60000);
   ctx->resize_width=probe_env_uint("RDP_PROBE_RESIZE_WIDTH",width,2,8192);
   ctx->resize_height=probe_env_uint("RDP_PROBE_RESIZE_HEIGHT",height,2,8192);
   /* Optional second sequential resize (same session); disabled by default. */
   ctx->resize2_width=probe_env_uint("RDP_PROBE_RESIZE2_WIDTH",0,2,8192);
   ctx->resize2_height=probe_env_uint("RDP_PROBE_RESIZE2_HEIGHT",0,2,8192);
   ctx->resize2_at_ms=probe_env_uint("RDP_PROBE_RESIZE2_AT_MS",
    (UINT32)(resize_at_ms+1200),0,60000);
   if (!ctx->resize2_width || !ctx->resize2_height) {
    ctx->resize2_width=ctx->resize2_height=0;
   }
  }
  UINT64 bench_start=GetTickCount64();
  UINT64 deadline=bench_start+((mode==9) ? bench_seconds*1000 :
   ((mode==3 || mode==4) ? 15000 : ((mode==10) ? 20000 :
    ((mode==11 || mode==12) ? (UINT64)ctx->clip_timeout_ms : 5000))));
  /* Protocol-tests regression hook: mode 0 must send its key/mouse input
   * after the first bitmap update even when the fit-with-bars desktop corners
   * are black (test_pattern=False letterboxed capture), where probe_paint never
   * sets ctx->frame. Default off: stdout and behaviour stay byte-identical. */
  BOOL input_force=probe_env_flag("RDP_PROBE_INPUT_AFTER_FIRST_BITMAP") ||
                   probe_env_flag("RDP_PROBE_FORCE_INPUT");
  BOOL sent=FALSE, announced=FALSE, disconnected=FALSE;
   BYTE initial_pixel[4]={0};
  while (GetTickCount64()<deadline && !freerdp_shall_disconnect_context(instance->context)) {
   HANDLE handles[64];
   DWORD count=freerdp_get_event_handles(instance->context,handles,64);
   if (!count || WaitForMultipleObjects(count,handles,FALSE,50)==WAIT_FAILED) {
    disconnected=TRUE;
    break;
   }
   if (!freerdp_check_event_handles(instance->context)) {
    disconnected=TRUE;
    break;
   }
   /* Suppress-output regression: see RDP_TEST_SUPPRESS_OUTPUT_AT_MS on the worker. */
    if (mode==8 && ctx->gfx_paint_seen) {
     puts("gfx_frame_ok");fflush(stdout);result=0;break;
    }
    if (ctx->frame && mode==1 && !announced) {
     puts("lease_held");fflush(stdout);announced=TRUE;deadline=GetTickCount64()+20000;
    }
    if (ctx->frame && !sent && mode==4) {
     RECTANGLE_16 area={0,0,WIDTH-1,HEIGHT-1};
     if (!instance->context->update->RefreshRect(instance->context,1,&area)) break;
     puts("refresh_requested");fflush(stdout);sent=TRUE;
    }
    if (mode==9 && refresh_at_ms && !sent &&
        GetTickCount64()-bench_start>=refresh_at_ms) {
     RECTANGLE_16 area={0,0,(UINT16)(ctx->width-1),(UINT16)(ctx->height-1)};
     if (!instance->context->update->RefreshRect(instance->context,1,&area)) break;
     puts("refresh_requested");fflush(stdout);sent=TRUE;
    }
      if ((ctx->frame || (input_force && mode==0 && ctx->bitmap_seen)) && !sent &&
          mode!=1 && mode!=4 && mode!=5 && mode!=6 && mode!=8 && mode!=9 &&
          mode!=10 && mode!=11 && mode!=12) {
      if (!ctx->frame) {puts("input_sent_after_first_bitmap");fflush(stdout);}
      if (!freerdp_input_send_keyboard_event(instance->context->input,0,0x1e) ||
          !freerdp_input_send_keyboard_event(instance->context->input,KBD_FLAGS_RELEASE,0x1e) ||
          !freerdp_input_send_mouse_event(instance->context->input,PTR_FLAGS_MOVE,100,100)) break;
      sent=TRUE;
     }
     if ((mode==3 || mode==4) && sent && !announced) {
      puts(mode==4 ? "refresh_stall_waiting" : "write_stall_waiting");fflush(stdout);
      Sleep(7000);
      announced=TRUE;
     }
   if (ctx->input_seen && mode!=1) {puts("bitmap_and_input_ok");fflush(stdout);result=0;break;}
   if (mode==11 || mode==12) {
    pthread_mutex_lock(&ctx->clip_mutex);
    BOOL clip_done=ctx->clip_done;
    BOOL clip_failed=ctx->clip_failed;
    const char *clip_stage=ctx->clip_stage ? ctx->clip_stage : "unknown";
    UINT64 clip_done_at=ctx->clip_done_at;
    UINT64 clip_failed_at=ctx->clip_failed_at;
    UINT32 clip_files=(mode==11) ? ctx->clip_offer_count : ctx->clip_rx_count;
    UINT32 clip_bytes=(mode==11) ? ctx->clip_offer_bytes : ctx->clip_bytes;
    pthread_mutex_unlock(&ctx->clip_mutex);
    UINT64 clip_elapsed=GetTickCount64()-bench_start;
    if (clip_done) {
     /* Mode 11: give the last queued CB_FILECONTENTS_RESPONSE time to flush
      * before the session is torn down, so the worker receives every byte. */
     if (mode==12 || GetTickCount64()-clip_done_at>=400) {
      printf("file_paste_ok files=%u bytes=%u\n",(unsigned)clip_files,(unsigned)clip_bytes);
      fflush(stdout);
      ctx->clip_reported=TRUE;result=0;break;
     }
    } else if (clip_failed) {
     /* Also flush first: injected/aborted responses must reach the worker so it
      * can log clipboard_file_rejected and emit the error offer end. */
     if (GetTickCount64()-clip_failed_at>=400) {
      printf("file_paste_failed reason=client_error stage=%s mode=%d\n",clip_stage,mode);
      fflush(stdout);ctx->clip_reported=TRUE;result=22;break;
     }
    } else if (clip_elapsed>=(UINT64)ctx->clip_timeout_ms) {
     printf("file_paste_failed reason=timeout stage=%s timeout_ms=%u mode=%d\n",
      clip_stage,(unsigned)ctx->clip_timeout_ms,mode);
     fflush(stdout);ctx->clip_reported=TRUE;result=22;break;
    }
   }
    if (mode==10) {
     UINT64 resize_elapsed=GetTickCount64()-bench_start;
     rdpGdi *resize_gdi=instance->context->gdi;
     if (!ctx->resize_sent && ctx->frame && ctx->disp && resize_elapsed>=resize_at_ms) {
      DISPLAY_CONTROL_MONITOR_LAYOUT layout={0};
      layout.Flags=DISPLAY_CONTROL_MONITOR_PRIMARY;
      layout.Width=ctx->resize_width;
      layout.Height=ctx->resize_height;
      layout.DesktopScaleFactor=100;
      layout.DeviceScaleFactor=100;
      if (ctx->disp->SendMonitorLayout &&
          ctx->disp->SendMonitorLayout(ctx->disp,1,&layout)==CHANNEL_RC_OK) {
       ctx->resize_sent=TRUE;
       printf("resize_requested width=%u height=%u\n",ctx->resize_width,ctx->resize_height);
       fflush(stdout);
      }
     }
     const UINT32 resize_tiles=((ctx->resize_width+63)/64)*((ctx->resize_height+63)/64);
     if (ctx->resize_sent && !ctx->resize_frame && ctx->reactivation_count>0 && resize_gdi &&
         resize_gdi->width==ctx->resize_width && resize_gdi->height==ctx->resize_height &&
         ctx->bitmap_rectangles>=ctx->bitmap_rectangles_at_resize+resize_tiles) {
      ctx->resize_frame=TRUE;
      printf("resize_frame_received width=%u height=%u\n",
       resize_gdi->width,resize_gdi->height);
      fflush(stdout);
      if (!ctx->resize2_width) {result=0;break;}
     }
     /* Optional second sequential resize in the same session (regression for the
      * WinPR manual-reset event drain): proves the DISP channel and the peer
      * thread still handle further client-driven resizes. */
     if (ctx->resize_frame && ctx->resize2_width && !ctx->resize2_sent && ctx->disp &&
         resize_elapsed>=ctx->resize2_at_ms) {
      DISPLAY_CONTROL_MONITOR_LAYOUT layout={0};
      layout.Flags=DISPLAY_CONTROL_MONITOR_PRIMARY;
      layout.Width=ctx->resize2_width;
      layout.Height=ctx->resize2_height;
      layout.DesktopScaleFactor=100;
      layout.DeviceScaleFactor=100;
      if (ctx->disp->SendMonitorLayout &&
          ctx->disp->SendMonitorLayout(ctx->disp,1,&layout)==CHANNEL_RC_OK) {
       ctx->resize2_sent=TRUE;
       printf("resize2_requested width=%u height=%u\n",
        ctx->resize2_width,ctx->resize2_height);
       fflush(stdout);
      }
     }
     const UINT32 resize2_tiles=((ctx->resize2_width+63)/64)*((ctx->resize2_height+63)/64);
     if (ctx->resize2_sent && !ctx->resize2_frame && ctx->reactivation_count>=2 && resize_gdi &&
         resize_gdi->width==ctx->resize2_width && resize_gdi->height==ctx->resize2_height &&
         ctx->bitmap_rectangles>=ctx->bitmap_rectangles_at_resize2+resize2_tiles) {
      ctx->resize2_frame=TRUE;
      printf("resize2_frame_received width=%u height=%u\n",
       resize_gdi->width,resize_gdi->height);
      fflush(stdout);result=0;break;
     }
     UINT64 resize_timeout_ms=ctx->resize2_width ? 30000 : 20000;
     if (resize_elapsed>=resize_timeout_ms) {
      printf("resize_timeout sent=%u reactivated=%u rectangles=%u resize2_sent=%u stage=%u\n",
       ctx->resize_sent ? 1u : 0u,ctx->reactivation_count,ctx->bitmap_rectangles,
       ctx->resize2_sent ? 1u : 0u,ctx->resize2_sent ? 3u : (ctx->resize_frame ? 2u : 1u));
      fflush(stdout);result=21;break;
     }
    }
    UINT32 expected_tiles=((ctx->width+63)/64)*((ctx->height+63)/64);
    if (mode==7 && ctx->surface_bits_seen && ctx->frame) {
     printf("nscodec_surface_bits_received codec=%u bytes=%u\n",ctx->surface_codec,ctx->surface_length);
     fflush(stdout);result=0;break;
    }
    if (mode==6 && ctx->bitmap_rectangles>=expected_tiles && instance->context->gdi &&
        ctx->width>80 && ctx->height>80) {
     rdpGdi *gdi=instance->context->gdi;
     BYTE *pixel=gdi->primary_buffer+(size_t)80*gdi->stride+80*4;
     if (!announced) {
      memcpy(initial_pixel,pixel,4);
      puts("initial_frame_received");fflush(stdout);announced=TRUE;
     } else if (!sent && ctx->bitmap_rectangles>expected_tiles && memcmp(initial_pixel,pixel,4)!=0) {
      RECTANGLE_16 area={0,0,(UINT16)(ctx->width-1),(UINT16)(ctx->height-1)};
      if (!instance->context->update->RefreshRect(instance->context,1,&area)) break;
      puts("dirty_frame_received");fflush(stdout);sent=TRUE;
     } else if (sent && ctx->bitmap_rectangles>=expected_tiles*2+1) {
      puts("full_refresh_received");fflush(stdout);result=0;break;
     }
    }
   if (mode==5 && ctx->bitmap_seen && ctx->bitmap_rectangles>=expected_tiles) {
    if (!ctx->samples_done) { ctx->samples_done=TRUE; probe_sample_pixels(ctx); }
    UINT32 gdi_width=instance->context->gdi ? instance->context->gdi->width : 0;
    UINT32 gdi_height=instance->context->gdi ? instance->context->gdi->height : 0;
      printf("bitmap_update_received\ndesktop_size=%ux%u\ngdi_size=%ux%u\nbitmap_update_batches=%u\nbitmap_rectangles=%u\nbitmap_flags=%u\n",
       ctx->width,ctx->height,gdi_width,gdi_height,ctx->bitmap_updates,ctx->bitmap_rectangles,ctx->bitmap_flags);
    fflush(stdout);result=0;break;
   }
  }
  if (mode==9) {
   UINT64 elapsed=GetTickCount64()-bench_start;
   if (!elapsed) elapsed=1;
   UINT32 framebuffer_crc=0;
   if (instance->context->gdi && instance->context->gdi->primary_buffer) {
    rdpGdi *gdi=instance->context->gdi;
    framebuffer_crc=probe_framebuffer_crc(gdi);
   }
   double seconds=(double)elapsed/1000.0;
   printf("bench seconds=%.3f bitmap_updates=%u bitmap_rectangles=%u bitmap_bytes=%llu "
          "pdu_per_s=%.2f mbit_per_s=%.3f gdi=%ux%u framebuffer_crc32=0x%08x\n",
          seconds,ctx->bitmap_updates,ctx->bitmap_rectangles,
          (unsigned long long)ctx->bitmap_bytes,
          (double)ctx->bitmap_updates/seconds,
          ((double)ctx->bitmap_bytes*8.0/1000000.0)/seconds,
          instance->context->gdi ? instance->context->gdi->width : 0,
          instance->context->gdi ? instance->context->gdi->height : 0,
          framebuffer_crc);
   fflush(stdout);
   result=ctx->bitmap_updates>0 ? 0 : 13;
  }
  if (mode==3 && announced && sent && ctx->frame && disconnected &&
      freerdp_get_last_error(instance->context)==FREERDP_ERROR_CONNECT_TRANSPORT_FAILED) {
   puts("server_close_observed");fflush(stdout);result=0;
  }
  if (mode==4 && announced && sent && ctx->frame && disconnected &&
      freerdp_get_last_error(instance->context)==FREERDP_ERROR_CONNECT_TRANSPORT_FAILED) {
   puts("refresh_close_observed");fflush(stdout);result=0;
  }
  if (!freerdp_disconnect(instance) && result!=0) result=12;
  if ((mode==11 || mode==12) && !ctx->clip_reported) {
   /* The loop can leave before the pump reports success (transport closed after
    * the last byte). Report the protocol outcome exactly once. */
   pthread_mutex_lock(&ctx->clip_mutex);
   BOOL clip_done=ctx->clip_done;
   BOOL clip_failed=ctx->clip_failed;
   const char *clip_stage=ctx->clip_stage ? ctx->clip_stage : "unknown";
   UINT32 clip_files=(mode==11) ? ctx->clip_offer_count : ctx->clip_rx_count;
   UINT32 clip_bytes=(mode==11) ? ctx->clip_offer_bytes : ctx->clip_bytes;
   pthread_mutex_unlock(&ctx->clip_mutex);
   if (clip_done) {
    printf("file_paste_ok files=%u bytes=%u\n",(unsigned)clip_files,(unsigned)clip_bytes);
    fflush(stdout);ctx->clip_reported=TRUE;result=0;
   } else {
    printf("file_paste_failed reason=%s stage=%s timeout_ms=%u mode=%d\n",
     clip_failed ? "client_error" : "timeout",clip_stage,
     (unsigned)ctx->clip_timeout_ms,mode);
    fflush(stdout);ctx->clip_reported=TRUE;result=22;
   }
  }
  gdi_free(instance);
 }
  if (ctx->bitmap_seen) {
   puts("bitmap_update_seen");
   printf("bitmap_bpp=%u\nbitmap_length=%u\nbitmap_compressed=%u\n",ctx->bitmap_bpp,ctx->bitmap_length,ctx->bitmap_compressed);
   fflush(stdout);
  }
  if (mode==11 || mode==12) probe_clip_free(ctx);
 freerdp_context_free(instance);freerdp_free(instance);
 return result;
}
