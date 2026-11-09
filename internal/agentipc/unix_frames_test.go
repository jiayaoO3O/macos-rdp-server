package agentipc

import (
	"bytes"
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestUnixFrameServerReassemblesBoundedFrame(t *testing.T) {
	directory := shortTempDir(t)
	path := filepath.Join(directory, "agent.sock")
	frames := make(chan Frame, 1)
	server, err := ListenUnixFrames(path, 4, 64, func(frame Frame) { frames <- frame })
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("socket mode = %o, want 600", info.Mode().Perm())
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()

	conn, err := net.Dial("unix", path)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	metadata := FrameBegin{Generation: 4, FrameID: 1, Width: 4, Height: 2, BytesPerPixel: 4}
	beginPayload, _ := EncodeFrameBegin(metadata)
	if err := WriteMessage(conn, Message{Type: FrameReady, Payload: beginPayload}); err != nil {
		t.Fatal(err)
	}
	pixels := []byte("0123456789abcdef0123456789abcdef")
	for offset := 0; offset < len(pixels); offset += 16 {
		chunkPayload, err := EncodeFrameChunk(FrameChunk{
			Generation: 4, FrameID: 1, Offset: uint32(offset), Data: pixels[offset : offset+16],
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := WriteMessage(conn, Message{Type: FrameChunkMessage, Payload: chunkPayload}); err != nil {
			t.Fatal(err)
		}
	}
	_ = conn.Close()
	select {
	case frame := <-frames:
		if frame.Metadata != metadata || !bytes.Equal(frame.Pixels, pixels) {
			t.Fatalf("frame = %#v", frame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for completed frame")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not stop after context cancellation")
	}
}

func TestListenUnixFramesRejectsUnsafePathAndExistingSocket(t *testing.T) {
	if _, err := ListenUnixFrames("relative.sock", 1, 1024, func(Frame) {}); err == nil {
		t.Fatal("accepted relative socket path")
	}
	shared := shortTempDir(t)
	if err := os.Chmod(shared, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := ListenUnixFrames(filepath.Join(shared, "agent.sock"), 1, 1024, func(Frame) {}); err == nil {
		t.Fatal("accepted non-private socket directory")
	}
	private := shortTempDir(t)
	path := filepath.Join(private, "agent.sock")
	server, err := ListenUnixFrames(path, 1, 1024, func(Frame) {})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ListenUnixFrames(path, 1, 1024, func(Frame) {}); err == nil {
		t.Fatal("replaced existing socket")
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
}

func shortTempDir(t *testing.T) string {
	t.Helper()
	// Unix socket paths must stay below 104 bytes. Prefer a short, writable
	// base directory and fall back to the platform TMPDIR only if it fits.
	for _, base := range []string{"/tmp", ""} {
		directory, err := os.MkdirTemp(base, "ipc-")
		if err != nil {
			continue
		}
		if len(filepath.Join(directory, "agent.sock")) < 104 {
			t.Cleanup(func() { _ = os.RemoveAll(directory) })
			return directory
		}
		_ = os.RemoveAll(directory)
	}
	t.Fatalf("no temp directory keeps the Unix socket path under 104 bytes")
	return ""
}
