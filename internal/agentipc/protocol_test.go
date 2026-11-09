package agentipc

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
)

type shortWriter struct {
	bytes.Buffer
	max int
}

func (w *shortWriter) Write(p []byte) (int, error) {
	if len(p) > w.max {
		p = p[:w.max]
	}
	return w.Buffer.Write(p)
}

func TestMessageRoundTripAcrossPartialIO(t *testing.T) {
	want := Message{Version: Version, Type: FrameReady, Payload: []byte("frame metadata only")}
	writer := &shortWriter{max: 2}
	if err := WriteMessage(writer, want); err != nil {
		t.Fatal(err)
	}
	got, err := ReadMessage(bytes.NewReader(writer.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != want.Version || got.Type != want.Type || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("decoded message = %#v, want %#v", got, want)
	}
}

func TestReadRejectsInvalidEnvelope(t *testing.T) {
	tests := []struct {
		name string
		data []byte
		want error
	}{
		{name: "truncated header", data: []byte("RDP")},
		{name: "bad magic", data: append([]byte("NOPE"), make([]byte, HeaderSize-4)...)},
		{name: "unknown type", data: envelopeForTest(99, nil)},
		{name: "unsupported version", data: envelopeForTestVersion(99, FrameReady, nil)},
		{name: "truncated payload", data: envelopeForTest(FrameReady, []byte{1, 2})[:HeaderSize+1]},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ReadMessage(bytes.NewReader(tt.data))
			if err == nil || (tt.want != nil && !errors.Is(err, tt.want)) {
				t.Fatalf("ReadMessage error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestWriteRejectsOversizedPayload(t *testing.T) {
	err := WriteMessage(io.Discard, Message{
		Version: Version,
		Type:    FrameReady,
		Payload: make([]byte, MaxPayloadSize+1),
	})
	if !errors.Is(err, ErrPayloadTooLarge) {
		t.Fatalf("WriteMessage error = %v, want ErrPayloadTooLarge", err)
	}
}

func TestFrameAssemblerPublishesOnlyCompleteCurrentGeneration(t *testing.T) {
	assembler := NewFrameAssembler(7, 32)
	begin := FrameBegin{Generation: 7, FrameID: 10, Width: 4, Height: 2, BytesPerPixel: 4}
	if err := assembler.Begin(begin); err != nil {
		t.Fatal(err)
	}
	if _, ok := assembler.Commit(); ok {
		t.Fatal("published incomplete frame")
	}
	pixels := []byte("0123456789abcdef0123456789abcdef")
	if err := assembler.Append(FrameChunk{Generation: 7, FrameID: 10, Offset: 16, Data: pixels[16:]}); err != nil {
		t.Fatal(err)
	}
	if err := assembler.Append(FrameChunk{Generation: 7, FrameID: 10, Offset: 0, Data: pixels[:16]}); err != nil {
		t.Fatal(err)
	}
	frame, ok := assembler.Commit()
	if !ok || !bytes.Equal(frame.Pixels, pixels) || frame.Metadata != begin {
		t.Fatalf("committed frame = %#v, ok=%v", frame, ok)
	}
}

func TestFrameAssemblerRejectsInvalidOrStaleChunks(t *testing.T) {
	tests := []struct {
		name  string
		chunk FrameChunk
	}{
		{name: "wrong generation", chunk: FrameChunk{Generation: 1, FrameID: 2, Offset: 0, Data: []byte{1}}},
		{name: "wrong frame", chunk: FrameChunk{Generation: 3, FrameID: 99, Offset: 0, Data: []byte{1}}},
		{name: "bad offset", chunk: FrameChunk{Generation: 3, FrameID: 2, Offset: 1, Data: []byte{1}}},
		{name: "empty chunk", chunk: FrameChunk{Generation: 3, FrameID: 2, Offset: 0}},
		{name: "past end", chunk: FrameChunk{Generation: 3, FrameID: 2, Offset: 16, Data: []byte{1}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := NewFrameAssembler(3, 32)
			if err := a.Begin(FrameBegin{Generation: 3, FrameID: 2, Width: 2, Height: 2, BytesPerPixel: 4}); err != nil {
				t.Fatal(err)
			}
			if err := a.Append(tt.chunk); err == nil {
				t.Fatal("accepted invalid chunk")
			}
		})
	}
}

func TestFrameAssemblerRejectsOversizeAndOldGeneration(t *testing.T) {
	a := NewFrameAssembler(9, 16)
	if err := a.Begin(FrameBegin{Generation: 8, FrameID: 1, Width: 1, Height: 1, BytesPerPixel: 4}); err == nil {
		t.Fatal("accepted stale generation")
	}
	if err := a.Begin(FrameBegin{Generation: 9, FrameID: 1, Width: 3, Height: 2, BytesPerPixel: 4}); err == nil {
		t.Fatal("accepted frame above configured cap")
	}
	if err := a.Begin(FrameBegin{Generation: 9, FrameID: 1, Width: 2, Height: 2, BytesPerPixel: 4}); err != nil {
		t.Fatal(err)
	}
	if err := a.Begin(FrameBegin{Generation: 9, FrameID: 2, Width: 1, Height: 1, BytesPerPixel: 4}); err == nil {
		t.Fatal("allowed overlapping in-flight frame")
	}
}

func TestFrameWireMetadataAndChunkRoundTrip(t *testing.T) {
	metadata := FrameBegin{Generation: 0x0102030405060708, FrameID: 9,
		Width: 1470, Height: 956, BytesPerPixel: 4}
	encodedMetadata, err := EncodeFrameBegin(metadata)
	if err != nil {
		t.Fatal(err)
	}
	decodedMetadata, err := DecodeFrameBegin(encodedMetadata)
	if err != nil || decodedMetadata != metadata {
		t.Fatalf("frame metadata decode = %#v, err=%v", decodedMetadata, err)
	}

	chunk := FrameChunk{Generation: metadata.Generation, FrameID: metadata.FrameID,
		Offset: 16, Data: []byte("pixels")}
	encodedChunk, err := EncodeFrameChunk(chunk)
	if err != nil {
		t.Fatal(err)
	}
	decodedChunk, err := DecodeFrameChunk(encodedChunk)
	if err != nil || decodedChunk.Generation != chunk.Generation ||
		decodedChunk.FrameID != chunk.FrameID || decodedChunk.Offset != chunk.Offset ||
		!bytes.Equal(decodedChunk.Data, chunk.Data) {
		t.Fatalf("frame chunk decode = %#v, err=%v", decodedChunk, err)
	}
}

func TestInputEventWireRoundTrip(t *testing.T) {
	want := AgentInputEvent{Kind: InputMouse, Flags: 0x0800, X: 1024, Y: 768}
	got, err := DecodeInputEvent(EncodeInputEvent(want))
	if err != nil || got != want {
		t.Fatalf("input event decode = %#v, err=%v, want %#v", got, err, want)
	}
	key := AgentInputEvent{Kind: InputScancode, Flags: 0x4000, Code: 0x1e}
	got, err = DecodeInputEvent(EncodeInputEvent(key))
	if err != nil || got != key {
		t.Fatalf("keyboard event decode = %#v, err=%v, want %#v", got, err, key)
	}
}

func envelopeForTest(kind MessageType, payload []byte) []byte {
	return envelopeForTestVersion(Version, kind, payload)
}

func envelopeForTestVersion(version uint16, kind MessageType, payload []byte) []byte {
	var buf bytes.Buffer
	buf.WriteString("RDPA")
	_ = binary.Write(&buf, binary.BigEndian, version)
	_ = binary.Write(&buf, binary.BigEndian, uint16(kind))
	_ = binary.Write(&buf, binary.BigEndian, uint32(len(payload)))
	buf.Write(payload)
	return buf.Bytes()
}
