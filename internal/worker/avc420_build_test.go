//go:build avc420

package worker

import "testing"

func TestAVC420BuildTagEnablesFFmpegCode(t *testing.T) {
	if !avc420BuildEnabled() {
		t.Fatal("avc420 build tag did not enable the optional FFmpeg encoder")
	}
}
