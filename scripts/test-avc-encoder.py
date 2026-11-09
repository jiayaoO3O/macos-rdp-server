#!/usr/bin/env python3
"""Standalone AVC tests; no worker, services, or private runtime data required."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument("--asan", action="store_true", help="instrument C harnesses with AddressSanitizer")
PARSER.add_argument("--require-ffmpeg", action="store_true", help="fail rather than skip missing FFmpeg development packages")
ARGS, REST = PARSER.parse_known_args()

STUB = r'''
#include "avc_encoder.h"
#include <assert.h>
#include <stdint.h>
int main(void) {
    const uint8_t *out = (const uint8_t *)(uintptr_t)1;
    size_t length = 42; int64_t pts = 7;
    assert(rdp_avc_encoder_create(320, 240, 60, 2000000) == NULL);
    assert(rdp_avc_encoder_encode(NULL, NULL, 0, 0, &out, &length, &pts) == -1);
    assert(out == NULL && length == 0 && pts == -1);
    assert(rdp_avc_encoder_encode(NULL, NULL, 0, 0, NULL, NULL, NULL) == -1);
    assert(rdp_avc_encoder_flush(NULL, &out, &length, &pts) == -1);
    assert(out == NULL && length == 0 && pts == -1);
    rdp_avc_encoder_destroy(NULL);
    return 0;
}
'''

INTERNAL_EAGAIN_RETRY = r'''
#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavutil/error.h>
#include <assert.h>
#include <stdint.h>
#include <string.h>
static int (*real_send_frame)(AVCodecContext *, const AVFrame *)=avcodec_send_frame;
static int (*real_receive_packet)(AVCodecContext *, AVPacket *)=avcodec_receive_packet;
static int (*real_bsf_send)(AVBSFContext *, AVPacket *)=av_bsf_send_packet;
static int (*real_bsf_receive)(AVBSFContext *, AVPacket *)=av_bsf_receive_packet;
static const AVFrame *first_frame;
static const AVPacket *first_packet;
static int codec_sends, codec_successes, codec_packet_pending=1;
static int bsf_sends, bsf_packet_pending;
static int injected_send_frame(AVCodecContext *ctx, const AVFrame *frame) {
    codec_sends++;
    if (codec_sends==1) { first_frame=frame; return AVERROR(EAGAIN); }
    assert(frame==first_frame);
    int rc=real_send_frame(ctx,frame);
    if (rc>=0) codec_successes++;
    return rc;
}
static int injected_receive_packet(AVCodecContext *ctx, AVPacket *packet) {
    if (codec_packet_pending) {
        codec_packet_pending=0;
        assert(av_new_packet(packet,2)==0);
        packet->data[0]=0xee; packet->data[1]=0x80; packet->pts=0; packet->dts=0;
        return 0;
    }
    return real_receive_packet(ctx,packet);
}
static int injected_bsf_send(AVBSFContext *ctx, AVPacket *packet) {
    if (packet->size==2 && packet->data[0]==0xee) {
        bsf_sends++;
        if (bsf_sends==1) { first_packet=packet; bsf_packet_pending=1; return AVERROR(EAGAIN); }
        assert(packet==first_packet && packet->pts==0 && packet->data[0]==0xee);
        return 0;
    }
    return real_bsf_send(ctx,packet);
}
static int injected_bsf_receive(AVBSFContext *ctx, AVPacket *packet) {
    if (bsf_packet_pending) {
        bsf_packet_pending=0;
        assert(av_new_packet(packet,1)==0);
        packet->data[0]=0x65; packet->pts=0; packet->dts=0;
        return 0;
    }
    return real_bsf_receive(ctx,packet);
}
#define avcodec_send_frame injected_send_frame
#define avcodec_receive_packet injected_receive_packet
#define av_bsf_send_packet injected_bsf_send
#define av_bsf_receive_packet injected_bsf_receive
#include "avc_encoder.c"
int main(void) {
    rdp_avc_encoder *e=rdp_avc_encoder_create(320,240,60,2000000);
    assert(e);
    uint8_t pixels[320*240*4]={0};
    const uint8_t *out=NULL; size_t length=0; int64_t pts=-1;
    int rc=rdp_avc_encoder_encode(e,pixels,sizeof(pixels),320*4,&out,&length,&pts);
    assert(rc==1 && out && length==1 && out[0]==0x65 && pts==0);
    assert(codec_sends==2 && codec_successes==1);
    assert(bsf_sends==2 && !bsf_packet_pending);
    rdp_avc_encoder_destroy(e);
    return 0;
}
'''

INTERNAL_NON_EOF_FLUSH = r'''
#include "avc_encoder.c"
#include <assert.h>
int main(void) {
    rdp_avc_encoder *e=rdp_avc_encoder_create(320,240,60,2000000);
    assert(e);
    e->codec_flush_sent=1;
    const uint8_t *out=NULL; size_t length=0; int64_t pts=-1;
    assert(rdp_avc_encoder_flush(e,&out,&length,&pts)==-1);
    assert(e->flush_started && !out && length==0 && pts==-1);
    e->codec_eof=1; e->filter_flush_sent=1;
    assert(rdp_avc_encoder_flush(e,&out,&length,&pts)==-1);
    assert(!out && length==0 && pts==-1);
    rdp_avc_encoder_destroy(e);
    return 0;
}
'''

INTERNAL_QUEUED_FLUSH = r'''
#include "avc_encoder.c"
#include <assert.h>
#include <stdint.h>
int main(void) {
    rdp_avc_encoder *e=rdp_avc_encoder_create(320,240,60,2000000);
    assert(e);
    assert(av_new_packet(e->ready[0],1)==0);
    e->ready[0]->data[0]=0x65; e->ready[0]->pts=0; e->ready_count=1;
    const uint8_t *out=NULL; size_t length=0; int64_t pts=-1;
    assert(rdp_avc_encoder_flush(e,&out,&length,&pts)==1);
    assert(out && length==1 && pts==0);
    assert(rdp_avc_encoder_encode(e,(const uint8_t[320*240*4]){0},320*240*4,320*4,
                                 &out,&length,&pts)==-1);
    assert(!out && length==0 && pts==-1);
    rdp_avc_encoder_destroy(e);
    return 0;
}
'''

ENABLED = r'''
#include "avc_encoder.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
enum { W = 320, H = 240, STRIDE = W * 4 + 32, FRAMES = 65 };
static void invalid(rdp_avc_encoder *e, const uint8_t *p, size_t n, size_t stride) {
    const uint8_t *out = (const uint8_t *)(uintptr_t)1;
    size_t length = 99; int64_t pts = 99;
    assert(rdp_avc_encoder_encode(e, p, n, stride, &out, &length, &pts) == -1);
    assert(out == NULL && length == 0 && pts == -1);
}
static void save_packet(FILE *f, const uint8_t *out, size_t length, int64_t pts,
                        int64_t upper_bound, unsigned *count) {
    assert(out && length > 0 && pts == (int64_t)*count && pts <= upper_bound);
    printf("packet_pts=%lld\n", (long long)pts);
    assert(fwrite(out, 1, length, f) == length);
    (*count)++;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    const int bad[][4] = {
        {0,H,60,2000000}, {-2,H,60,2000000}, {W,0,60,2000000},
        {W,-2,60,2000000}, {319,H,60,2000000}, {W,239,60,2000000},
        {INT_MAX,H,60,2000000}, {W,INT_MAX,60,2000000},
        {8192,8192,60,2000000}, {W,H,0,2000000}, {W,H,241,2000000},
        {W,H,-1,2000000}, {W,H,60,0}, {W,H,60,-1}
    };
    for (size_t i = 0; i < sizeof(bad)/sizeof(bad[0]); i++)
        assert(!rdp_avc_encoder_create(bad[i][0],bad[i][1],bad[i][2],bad[i][3]));
    rdp_avc_encoder *e = rdp_avc_encoder_create(W,H,60,2000000);
    assert(e && "VideoToolbox hardware encoder must open (no software fallback)");
    size_t n = (H-1)*STRIDE + W*4;
    uint8_t *pixels = malloc(n);
    assert(pixels);
    memset(pixels, 0xcc, n);
    invalid(NULL, pixels, n, STRIDE);
    invalid(e, NULL, n, STRIDE);
    invalid(e, pixels, n-1, STRIDE);
    invalid(e, pixels, 0, STRIDE);
    invalid(e, pixels, n, W*4-1);
    invalid(e, pixels, n, 0);
    invalid(e, pixels, SIZE_MAX, SIZE_MAX);
    invalid(e, pixels, SIZE_MAX, (size_t)INT_MAX+1);
    const uint8_t *out = (const uint8_t *)(uintptr_t)1;
    size_t length = 7; int64_t pts = 99;
    assert(rdp_avc_encoder_encode(e,pixels,n,STRIDE,NULL,&length,&pts) == -1 && length == 0 && pts == -1);
    assert(rdp_avc_encoder_encode(e,pixels,n,STRIDE,&out,NULL,&pts) == -1 && out == NULL && pts == -1);
    assert(rdp_avc_encoder_encode(e,pixels,n,STRIDE,&out,&length,NULL) == -1 && out == NULL && length == 0);
    assert(rdp_avc_encoder_flush(NULL,&out,&length,&pts) == -1 && out == NULL && length == 0 && pts == -1);
    FILE *f = fopen(argv[1], "wb");
    assert(f);
    static const uint8_t rgb[5][3] = {{255,0,0},{0,255,0},{0,0,255},{255,255,255},{0,0,0}};
    static const uint8_t gray[5][3] = {{32,32,32},{64,64,64},{128,128,128},{192,192,192},{224,224,224}};
    unsigned count = 0;
    for (int frame = 0; frame < FRAMES; frame++) {
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            uint8_t *p = pixels + y*STRIDE+x*4;
            const uint8_t *c = y < H/2 ? rgb[x/(W/5)] : gray[x/(W/5)];
            p[0]=c[2]; p[1]=c[1]; p[2]=c[0]; p[3]=255;
        }
        int left=(frame*8)%(W-32);
        for (int y=200; y<232; y++) for (int x=left; x<left+32; x++) {
            uint8_t *p=pixels+y*STRIDE+x*4; p[0]=p[1]=p[2]=255; p[3]=255;
        }
        pts=-1;
        int rc=rdp_avc_encoder_encode(e,pixels,n,STRIDE,&out,&length,&pts);
        assert(rc>=0);
        uint8_t *copy=NULL;
        if (rc==1) {
            save_packet(f,out,length,pts,frame,&count);
            copy=malloc(length); assert(copy); memcpy(copy,out,length);
        } else assert(!out && length==0 && pts==-1);
        memset(pixels,0,n); /* codec must not retain caller pixels */
        if (copy) { assert(memcmp(copy,out,length)==0); free(copy); }
        if (frame==0) {
            rdp_avc_encoder *other=rdp_avc_encoder_create(W,H,60,2000000);
            assert(other);
            const uint8_t *other_out=NULL; size_t other_length=0; int64_t other_pts=-1;
            int other_rc=rdp_avc_encoder_encode(other,pixels,n,STRIDE,&other_out,&other_length,&other_pts);
            assert(other_rc>=0);
            if (other_rc==1) assert(other_pts==0 && other_out && other_out!=out);
            else assert(!other_out && other_length==0 && other_pts==-1);
            while ((other_rc=rdp_avc_encoder_flush(other,&other_out,&other_length,&other_pts))==1)
                assert(other_pts==0 && other_out && other_length>0);
            assert(other_rc==0);
            rdp_avc_encoder_destroy(other);
        }
    }
    int rc=-1;
    for (unsigned i=0; i<FRAMES+8; i++) {
        rc=rdp_avc_encoder_flush(e,&out,&length,&pts);
        assert(rc>=0);
        if (rc==0) break;

        save_packet(f,out,length,pts,FRAMES-1,&count);
    }
    assert(rc==0 && count==FRAMES);
    pts=99; out=(const uint8_t *)(uintptr_t)1; length=99;
    assert(rdp_avc_encoder_encode(e,pixels,n,STRIDE,&out,&length,&pts)==-1);
    assert(!out && length==0 && pts==-1);
    assert(fclose(f)==0);
    free(pixels);
    rdp_avc_encoder_destroy(e);
    rdp_avc_encoder_destroy(NULL);
    return 0;
}
'''

class EncoderTests(unittest.TestCase):
    def compile_run(self, source, enabled=False, args=(), extra_flags=(), include_encoder=True):
        with tempfile.TemporaryDirectory(prefix="rdp-avc-test-") as tmp:
            tmp = Path(tmp)
            harness = tmp / "test.c"
            binary = tmp / "test"
            harness.write_text(source)
            command = shlex.split(os.environ.get("CC", "cc"))
            command += ["-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "internal/worker")]
            command += list(extra_flags)
            if ARGS.asan:
                command += ["-fsanitize=address", "-fno-omit-frame-pointer", "-g"]
            if enabled:
                command += ["-DRDP_WITH_FFMPEG=1"] + self.ffmpeg_flags
            sources = [str(harness)]
            if include_encoder:
                sources.append(str(ROOT / "internal/worker/avc_encoder.c"))
            command += sources + ["-o", str(binary)]
            compiled = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_stub_has_no_ffmpeg_dependency(self):
        self.compile_run(STUB)
        self.compile_run(STUB, extra_flags=["-DRDP_WITH_FFMPEG=0"])

    def test_enabled_hardware_bounds_annexb_delayed_pts_and_decoded_bt709_color_and_motion(self):
        packages = ["libavcodec", "libavutil", "libswscale"]
        if not shutil.which("pkg-config"):
            if ARGS.require_ffmpeg:
                self.fail("pkg-config required")
            self.skipTest("pkg-config unavailable")
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", *packages], capture_output=True, text=True)
        if flags.returncode:
            if ARGS.require_ffmpeg:
                self.fail(flags.stderr)
            self.skipTest("FFmpeg development packages unavailable")
        self.ffmpeg_flags = shlex.split(flags.stdout)
        self.assertTrue(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg and ffprobe required for real decode")
        with tempfile.TemporaryDirectory(prefix="rdp-avc-decode-") as tmp:
            stream = Path(tmp) / "synthetic.h264"
            self.compile_run(INTERNAL_EAGAIN_RETRY, enabled=True, include_encoder=False)
            self.compile_run(INTERNAL_NON_EOF_FLUSH, enabled=True, include_encoder=False)
            self.compile_run(INTERNAL_QUEUED_FLUSH, enabled=True, include_encoder=False)
            output = self.compile_run(ENABLED, enabled=True, args=[stream])
            packet_pts = [int(v) for v in re.findall(r"packet_pts=(\d+)", output)]
            self.assertEqual(packet_pts, list(range(65)), "every input frame, including delayed tail, must retain its PTS")
            data = stream.read_bytes()
            nals = [part[0] & 31 for part in re.split(b"\x00\x00(?:\x00)?\x01", data)[1:] if part]
            self.assertIn(7, nals, "AnnexB SPS missing")
            self.assertIn(8, nals, "AnnexB PPS missing")
            vcl = [kind for kind in nals if kind in (1, 5)]
            self.assertEqual(len(vcl), 65)
            self.assertEqual(vcl[0], 5, "first picture must be IDR")
            self.assertGreaterEqual(vcl.count(5), 2, "GOP interval should produce a later IDR")
            self.assertGreaterEqual(nals.count(7), 2, "later IDR should refresh SPS")
            self.assertGreaterEqual(nals.count(8), 2, "later IDR should refresh PPS")
            probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(stream)], capture_output=True, text=True)
            self.assertEqual(probe.returncode, 0, probe.stderr)
            info = json.loads(probe.stdout)["streams"][0]
            self.assertEqual((info["width"], info["height"]), (320, 240))
            self.assertEqual(info["has_b_frames"], 0)
            self.assertEqual(info["color_range"], "tv")
            for key in ("color_space", "color_transfer", "color_primaries"):
                self.assertEqual(info[key], "bt709")
            decoded = subprocess.run(["ffmpeg", "-v", "error", "-i", str(stream), "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"], capture_output=True)
            self.assertEqual(decoded.returncode, 0, decoded.stderr.decode())
            frame_bytes = 320*240*3
            self.assertEqual(len(decoded.stdout), 65*frame_bytes)
            colors = [(255,0,0), (0,255,0), (0,0,255), (255,255,255), (0,0,0)]
            gray = [(v,v,v) for v in (32,64,128,192,224)]
            for frame in (0, 1, 23, 64):
                for y, palette in ((60, colors), (180, gray)):
                    for band, expected in enumerate(palette):
                        pos = frame*frame_bytes + (y*320 + band*64 + 32)*3
                        actual = decoded.stdout[pos:pos+3]
                        self.assertTrue(all(abs(a-b) <= 12 for a,b in zip(actual,expected)), (frame, y, band, list(actual), expected))
            for frame in (0,64):
                left=(frame*8)%(320-32)
                pos=frame*frame_bytes+(216*320+left+16)*3
                self.assertTrue(all(v>220 for v in decoded.stdout[pos:pos+3]), (frame, left, list(decoded.stdout[pos:pos+3])))

if __name__ == "__main__":
    unittest.main(argv=[__file__, *REST], verbosity=2)
