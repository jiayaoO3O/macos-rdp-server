package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"rdp-server/internal/config"
	"rdp-server/internal/worker"
	"strings"
	"syscall"
	"time"
)

func main() {
	path := flag.String("config", ".runtime/config.json", "private P0 configuration")
	agentSocket := flag.String("agent-socket", ".runtime/agent.sock", "private logged-in Agent Unix socket")
	flag.Parse()
	c, err := config.Load(*path)
	if err != nil {
		log.Fatal(err)
	}
	if c.AutoLAN && os.Getenv("RDP_WORKER_SUPERVISED_CHILD") != "1" {
		if err := superviseLAN(*path, *agentSocket); err != nil {
			log.Fatal(err)
		}
		return
	}
	agentSocketPath, err := filepath.Abs(*agentSocket)
	if err != nil {
		log.Fatal(err)
	}
	backend := "logged-in desktop"
	if c.TestPattern {
		backend = "test-pattern (explicit development mode)"
	}
	if c.AutoLAN {
		log.Printf("event=lan_address_selected interface=%s address=%s", c.LANInterface, c.Address)
	}
	if err = runWorker(c, agentSocketPath, backend); err != nil {
		log.Fatal(err)
	}
}

func runWorker(c config.Config, agentSocketPath, backend string) error {
	log.Printf("P0 worker: %s:%d; domain=MACRDP; Agent IPC=%s; backend=%s; clipboard=%t; max-frame=%dMiB",
		c.Address, c.Port, agentSocketPath, backend, c.Clipboard, 64)
	return worker.Serve(c.Address, c.Port, c.Certificate, c.Key, c.SAM, agentSocketPath,
		c.Account, c.Enabled, c.TestPattern, c.Clipboard)
}

// superviseLAN restarts the FreeRDP child when the selected private LAN IPv4
// changes, while keeping the listener bound only to that exact private address.
func superviseLAN(configPath, agentSocket string) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	for ctx.Err() == nil {
		c, err := config.Load(configPath)
		if err != nil {
			log.Printf("event=lan_address_unavailable error=%v", err)
			if !sleepContext(ctx, 2*time.Second) {
				return nil
			}
			continue
		}
		if c.LANInterface != "" {
			log.Printf("event=lan_address_selected interface=%s address=%s", c.LANInterface, c.Address)
		}
		cmd := exec.Command(executable, "-config", configPath, "-agent-socket", agentSocket)
		cmd.Env = childEnvironment(c.Address)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Start(); err != nil {
			log.Printf("event=lan_worker_start_failed error=%v", err)
			if !sleepContext(ctx, 2*time.Second) {
				return nil
			}
			continue
		}
		log.Printf("event=lan_worker_started address=%s pid=%d", c.Address, cmd.Process.Pid)
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		ticker := time.NewTicker(2 * time.Second)
		restart := false
		for !restart {
			select {
			case err := <-done:
				if err != nil && ctx.Err() == nil {
					log.Printf("event=lan_worker_exited error=%v", err)
				}
				restart = true
			case <-ticker.C:
				address, iface, err := config.DiscoverLANAddress()
				if err != nil {
					log.Printf("event=lan_address_unavailable error=%v", err)
					continue
				}
				if address.String() == c.Address {
					continue
				}
				log.Printf("event=lan_address_changed old=%s new=%s interface=%s", c.Address, address, iface)
				stopChild(cmd, done)
				restart = true
			case <-ctx.Done():
				ticker.Stop()
				stopChild(cmd, done)
				return nil
			}
		}
		ticker.Stop()
		if ctx.Err() == nil {
			if !sleepContext(ctx, time.Second) {
				return nil
			}
		}
	}
	return nil
}

func childEnvironment(address string) []string {
	env := make([]string, 0, len(os.Environ())+2)
	for _, entry := range os.Environ() {
		if strings.HasPrefix(entry, "RDP_WORKER_RESOLVED_ADDRESS=") ||
			strings.HasPrefix(entry, "RDP_WORKER_SUPERVISED_CHILD=") {
			continue
		}
		env = append(env, entry)
	}
	return append(env, "RDP_WORKER_RESOLVED_ADDRESS="+address, "RDP_WORKER_SUPERVISED_CHILD=1")
}

func stopChild(cmd *exec.Cmd, done <-chan error) {
	if cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
}

func sleepContext(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}
