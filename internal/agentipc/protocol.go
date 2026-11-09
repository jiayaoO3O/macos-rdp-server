// Package agentipc defines the bounded control-message envelope shared by the
// logged-in macOS Agent and the RDP Worker. Large frame pixels are out-of-band.
package agentipc

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	Version        uint16 = 1
	HeaderSize            = 12
	MaxPayloadSize        = 64 * 1024
)

var (
	ErrInvalidMagic       = errors.New("invalid Agent IPC magic")
	ErrUnsupportedVersion = errors.New("unsupported Agent IPC version")
	ErrUnknownMessageType = errors.New("unknown Agent IPC message type")
	ErrPayloadTooLarge    = errors.New("Agent IPC payload exceeds limit")
)

type MessageType uint16

const (
	RegisterAgent MessageType = iota + 1
	FrameReady
	InputEvent
	ReleaseInput
	RequestKeyframe
	Disconnect
	FrameChunkMessage
	ClipboardData
)

type Message struct {
	Version uint16
	Type    MessageType
	Payload []byte
}

func validMessageType(kind MessageType) bool {
	return (kind >= RegisterAgent && kind <= Disconnect) || (kind >= FrameChunkMessage && kind <= ClipboardData)
}

// WriteMessage writes one versioned RDPA envelope, handling short writes.
func WriteMessage(w io.Writer, message Message) error {
	version := message.Version
	if version == 0 {
		version = Version
	}
	if version != Version {
		return fmt.Errorf("%w: %d", ErrUnsupportedVersion, version)
	}
	if !validMessageType(message.Type) {
		return fmt.Errorf("%w: %d", ErrUnknownMessageType, message.Type)
	}
	if len(message.Payload) > MaxPayloadSize {
		return ErrPayloadTooLarge
	}

	header := make([]byte, HeaderSize)
	copy(header[:4], "RDPA")
	binary.BigEndian.PutUint16(header[4:6], version)
	binary.BigEndian.PutUint16(header[6:8], uint16(message.Type))
	binary.BigEndian.PutUint32(header[8:12], uint32(len(message.Payload)))
	if err := writeFull(w, header); err != nil {
		return err
	}
	return writeFull(w, message.Payload)
}

// ReadMessage reads one bounded RDPA envelope. io.ReadFull permits Unix socket
// reads to split either the header or payload across multiple system calls.
func ReadMessage(r io.Reader) (Message, error) {
	var message Message
	header := make([]byte, HeaderSize)
	if _, err := io.ReadFull(r, header); err != nil {
		return message, err
	}
	if string(header[:4]) != "RDPA" {
		return message, ErrInvalidMagic
	}
	message.Version = binary.BigEndian.Uint16(header[4:6])
	if message.Version != Version {
		return Message{}, fmt.Errorf("%w: %d", ErrUnsupportedVersion, message.Version)
	}
	message.Type = MessageType(binary.BigEndian.Uint16(header[6:8]))
	if !validMessageType(message.Type) {
		return Message{}, fmt.Errorf("%w: %d", ErrUnknownMessageType, message.Type)
	}
	length := binary.BigEndian.Uint32(header[8:12])
	if length > MaxPayloadSize {
		return Message{}, ErrPayloadTooLarge
	}
	if length == 0 {
		return message, nil
	}
	message.Payload = make([]byte, int(length))
	if _, err := io.ReadFull(r, message.Payload); err != nil {
		return Message{}, err
	}
	return message, nil
}

func writeFull(w io.Writer, p []byte) error {
	for len(p) > 0 {
		n, err := w.Write(p)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		p = p[n:]
	}
	return nil
}
