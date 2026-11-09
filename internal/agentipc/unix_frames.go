package agentipc

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
)

// UnixFrameServer accepts the logged-in Agent's bounded frame messages.
// The socket is private to its owner; remote RDP clients never connect here.
type UnixFrameServer struct {
	listener *net.UnixListener
	path     string
	onFrame  func(Frame)
	gen      uint64
	maxBytes uint64
	once     sync.Once
	closed   chan struct{}
}

func ListenUnixFrames(path string, generation, maxFrameBytes uint64, onFrame func(Frame)) (*UnixFrameServer, error) {
	if !filepath.IsAbs(path) || len(path) >= 104 {
		return nil, fmt.Errorf("Agent IPC socket path must be absolute and shorter than 104 bytes")
	}
	if generation == 0 || maxFrameBytes == 0 || onFrame == nil {
		return nil, fmt.Errorf("invalid Agent IPC server options")
	}
	parent, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	if !parent.IsDir() || parent.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("Agent IPC socket directory must be private (0700 or stricter)")
	}
	if _, err := os.Lstat(path); err == nil {
		return nil, fmt.Errorf("Agent IPC socket path already exists")
	} else if !os.IsNotExist(err) {
		return nil, err
	}

	address := &net.UnixAddr{Name: path, Net: "unix"}
	listener, err := net.ListenUnix("unix", address)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0600); err != nil {
		listener.Close()
		os.Remove(path)
		return nil, err
	}
	return &UnixFrameServer{
		listener: listener,
		path:     path,
		onFrame:  onFrame,
		gen:      generation,
		maxBytes: maxFrameBytes,
		closed:   make(chan struct{}),
	}, nil
}

func (s *UnixFrameServer) Serve(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		_ = s.Close()
	}()
	defer s.Close()
	for {
		conn, err := s.listener.AcceptUnix()
		if err != nil {
			select {
			case <-s.closed:
				return nil
			default:
			}
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if err := s.handleConnection(conn); err != nil {
			_ = conn.Close()
			continue
		}
		_ = conn.Close()
	}
}

func (s *UnixFrameServer) handleConnection(conn net.Conn) error {
	assembler := NewFrameAssembler(s.gen, s.maxBytes)
	for {
		message, err := ReadMessage(conn)
		if err != nil {
			return err
		}
		switch message.Type {
		case FrameReady:
			metadata, err := DecodeFrameBegin(message.Payload)
			if err != nil {
				return err
			}
			if err := assembler.Begin(metadata); err != nil {
				return err
			}
		case FrameChunkMessage:
			chunk, err := DecodeFrameChunk(message.Payload)
			if err != nil {
				return err
			}
			if err := assembler.Append(chunk); err != nil {
				return err
			}
			if frame, ok := assembler.Commit(); ok {
				s.onFrame(frame)
			}
		default:
			return fmt.Errorf("unexpected Agent IPC message type %d", message.Type)
		}
	}
}

func (s *UnixFrameServer) Close() error {
	var closeErr error
	s.once.Do(func() {
		close(s.closed)
		closeErr = s.listener.Close()
		if err := os.Remove(s.path); err != nil && !os.IsNotExist(err) && closeErr == nil {
			closeErr = err
		}
	})
	return closeErr
}
