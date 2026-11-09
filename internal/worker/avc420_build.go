//go:build avc420

package worker

/*
#cgo CFLAGS: -DRDP_WITH_FFMPEG=1
#cgo pkg-config: libavcodec libavutil libswscale
#include "avc_encoder.h"
#if defined(RDP_WITH_FFMPEG) && RDP_WITH_FFMPEG
static int rdp_avc420_build_marker(void) { return 1; }
#else
static int rdp_avc420_build_marker(void) { return 0; }
#endif
*/
import "C"

// avc420BuildEnabled is referenced by a build-tagged regression test; the tag
// is deliberately opt-in and never changes the default worker binary.
func avc420BuildEnabled() bool { return C.rdp_avc420_build_marker() == 1 }
