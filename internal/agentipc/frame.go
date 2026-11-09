package agentipc

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const MaxFrameDimension = 16384

var (
	ErrStaleGeneration = errors.New("stale frame generation")
	ErrFrameInFlight   = errors.New("a frame is already in flight")
	ErrInvalidFrame    = errors.New("invalid frame metadata")
	ErrInvalidChunk    = errors.New("invalid frame chunk")
	ErrIncompleteFrame = errors.New("frame is incomplete")
)

const (
	FrameBeginPayloadSize = 25
	FrameChunkHeaderSize  = 20
	MaxFrameChunkData     = MaxPayloadSize - FrameChunkHeaderSize
)

type InputKind uint8

const (
	InputMouse InputKind = iota + 1
	InputScancode
	InputUnicode
	InputReleaseAll
)

type AgentInputEvent struct {
	Kind  InputKind
	Flags uint16
	Code  uint16
	X     uint16
	Y     uint16
}

func EncodeInputEvent(event AgentInputEvent) []byte {
	payload := make([]byte, 9)
	payload[0] = byte(event.Kind)
	binary.BigEndian.PutUint16(payload[1:3], event.Flags)
	binary.BigEndian.PutUint16(payload[3:5], event.Code)
	binary.BigEndian.PutUint16(payload[5:7], event.X)
	binary.BigEndian.PutUint16(payload[7:9], event.Y)
	return payload
}

func DecodeInputEvent(payload []byte) (AgentInputEvent, error) {
	if len(payload) != 9 || payload[0] < byte(InputMouse) || payload[0] > byte(InputReleaseAll) {
		return AgentInputEvent{}, ErrInvalidChunk
	}
	return AgentInputEvent{
		Kind:  InputKind(payload[0]),
		Flags: binary.BigEndian.Uint16(payload[1:3]),
		Code:  binary.BigEndian.Uint16(payload[3:5]),
		X:     binary.BigEndian.Uint16(payload[5:7]),
		Y:     binary.BigEndian.Uint16(payload[7:9]),
	}, nil
}

type FrameBegin struct {
	Generation    uint64
	FrameID       uint64
	Width         uint32
	Height        uint32
	BytesPerPixel uint8
}

type FrameChunk struct {
	Generation uint64
	FrameID    uint64
	Offset     uint32
	Data       []byte
}

type Frame struct {
	Metadata FrameBegin
	Pixels   []byte
}

func EncodeFrameBegin(metadata FrameBegin) ([]byte, error) {
	if metadata.Generation == 0 || metadata.FrameID == 0 || metadata.Width == 0 ||
		metadata.Height == 0 || metadata.BytesPerPixel == 0 || metadata.BytesPerPixel > 4 {
		return nil, ErrInvalidFrame
	}
	payload := make([]byte, FrameBeginPayloadSize)
	binary.BigEndian.PutUint64(payload[0:8], metadata.Generation)
	binary.BigEndian.PutUint64(payload[8:16], metadata.FrameID)
	binary.BigEndian.PutUint32(payload[16:20], metadata.Width)
	binary.BigEndian.PutUint32(payload[20:24], metadata.Height)
	payload[24] = metadata.BytesPerPixel
	return payload, nil
}

func DecodeFrameBegin(payload []byte) (FrameBegin, error) {
	if len(payload) != FrameBeginPayloadSize {
		return FrameBegin{}, ErrInvalidFrame
	}
	metadata := FrameBegin{
		Generation:    binary.BigEndian.Uint64(payload[0:8]),
		FrameID:       binary.BigEndian.Uint64(payload[8:16]),
		Width:         binary.BigEndian.Uint32(payload[16:20]),
		Height:        binary.BigEndian.Uint32(payload[20:24]),
		BytesPerPixel: payload[24],
	}
	if metadata.Generation == 0 || metadata.FrameID == 0 || metadata.Width == 0 ||
		metadata.Height == 0 || metadata.BytesPerPixel == 0 || metadata.BytesPerPixel > 4 {
		return FrameBegin{}, ErrInvalidFrame
	}
	return metadata, nil
}

func EncodeFrameChunk(chunk FrameChunk) ([]byte, error) {
	if chunk.Generation == 0 || chunk.FrameID == 0 || len(chunk.Data) == 0 || len(chunk.Data) > MaxFrameChunkData {
		return nil, ErrInvalidChunk
	}
	payload := make([]byte, FrameChunkHeaderSize+len(chunk.Data))
	binary.BigEndian.PutUint64(payload[0:8], chunk.Generation)
	binary.BigEndian.PutUint64(payload[8:16], chunk.FrameID)
	binary.BigEndian.PutUint32(payload[16:20], chunk.Offset)
	copy(payload[20:], chunk.Data)
	return payload, nil
}

func DecodeFrameChunk(payload []byte) (FrameChunk, error) {
	if len(payload) <= FrameChunkHeaderSize || len(payload) > MaxPayloadSize {
		return FrameChunk{}, ErrInvalidChunk
	}
	chunk := FrameChunk{
		Generation: binary.BigEndian.Uint64(payload[0:8]),
		FrameID:    binary.BigEndian.Uint64(payload[8:16]),
		Offset:     binary.BigEndian.Uint32(payload[16:20]),
		Data:       append([]byte(nil), payload[20:]...),
	}
	if chunk.Generation == 0 || chunk.FrameID == 0 {
		return FrameChunk{}, ErrInvalidChunk
	}
	return chunk, nil
}

type FrameAssembler struct {
	generation uint64
	maxBytes   uint64
	metadata   FrameBegin
	pixels     []byte
	seen       []bool
	received   uint64
}

func NewFrameAssembler(generation uint64, maxBytes uint64) *FrameAssembler {
	return &FrameAssembler{generation: generation, maxBytes: maxBytes}
}

// SetGeneration invalidates any partial frame from an older desktop session.
func (a *FrameAssembler) SetGeneration(generation uint64) {
	a.generation = generation
	a.reset()
}

func (a *FrameAssembler) Begin(metadata FrameBegin) error {
	if metadata.Generation != a.generation {
		return ErrStaleGeneration
	}
	if metadata.FrameID == 0 || metadata.Width == 0 || metadata.Height == 0 ||
		metadata.Width > MaxFrameDimension || metadata.Height > MaxFrameDimension ||
		metadata.BytesPerPixel == 0 || metadata.BytesPerPixel > 4 {
		return ErrInvalidFrame
	}
	if len(a.pixels) != 0 {
		return ErrFrameInFlight
	}
	size := uint64(metadata.Width) * uint64(metadata.Height) * uint64(metadata.BytesPerPixel)
	if size == 0 || size > a.maxBytes || size > uint64(^uint(0)>>1) {
		return fmt.Errorf("%w: %d bytes", ErrInvalidFrame, size)
	}
	a.metadata = metadata
	a.pixels = make([]byte, int(size))
	a.seen = make([]bool, int(size))
	a.received = 0
	return nil
}

func (a *FrameAssembler) Append(chunk FrameChunk) error {
	if len(a.pixels) == 0 {
		return ErrInvalidChunk
	}
	if chunk.Generation != a.generation || chunk.Generation != a.metadata.Generation {
		return ErrStaleGeneration
	}
	if chunk.FrameID != a.metadata.FrameID || len(chunk.Data) == 0 || chunk.Offset%4 != 0 ||
		uint64(chunk.Offset)+uint64(len(chunk.Data)) > uint64(len(a.pixels)) {
		return ErrInvalidChunk
	}
	start := int(chunk.Offset)
	end := start + len(chunk.Data)
	for i := start; i < end; i++ {
		if a.seen[i] {
			return ErrInvalidChunk
		}
	}
	copy(a.pixels[start:end], chunk.Data)
	for i := start; i < end; i++ {
		a.seen[i] = true
	}
	a.received += uint64(len(chunk.Data))
	return nil
}

func (a *FrameAssembler) Commit() (Frame, bool) {
	if len(a.pixels) == 0 || a.received != uint64(len(a.pixels)) {
		return Frame{}, false
	}
	frame := Frame{Metadata: a.metadata, Pixels: a.pixels}
	a.reset()
	return frame, true
}

func (a *FrameAssembler) reset() {
	a.metadata = FrameBegin{}
	a.pixels = nil
	a.seen = nil
	a.received = 0
}
