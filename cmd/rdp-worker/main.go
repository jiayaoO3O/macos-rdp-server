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
	if appManagedWorker() {
		go watchStandaloneParent()
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

const (
	managedByAppEnv           = "RDP_WORKER_MANAGED_BY_APP"
	managedParentPollInterval = 500 * time.Millisecond
)

func appManagedWorker() bool { return os.Getenv(managedByAppEnv) == "1" }

// superviseLAN restarts the FreeRDP child when the selected private LAN IPv4
// changes, while keeping the listener bound only to that exact private address.
func superviseLAN(configPath, agentSocket string) error {
	socketPath, err := filepath.Abs(agentSocket)
	if err != nil {
		return err
	}
	// Every exit path stops the child first (or never started one); removing
	// the socket here also covers a parent death during the restart delay.
	defer func() { _ = os.Remove(socketPath) }()
	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// Keep signal handling installed while the parent watchdog cancels ctx;
	// otherwise a concurrent SIGTERM could skip stopping the child.
	ctx, cancel := context.WithCancel(signalCtx)
	defer cancel()
	if appManagedWorker() {
		go watchSupervisorParent(ctx, cancel)
	}
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
		// The previous child never unlinks its socket on crash or SIGTERM.
		// Without this the C listener silently refuses to listen on the
		// existing path, so remove it before every child start.
		if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
			log.Printf("event=lan_socket_remove_failed error=%v", err)
		}
		cmd := exec.Command(executable, "-config", configPath, "-agent-socket", socketPath)
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

// watchSupervisorParent stops the LAN supervisor when the App that spawned it
// disappears. macOS reparents orphaned children to launchd (PID 1); without
// this the supervisor and its FreeRDP child keep listening after an App crash
// or SIGKILL. The watchdog is opt-in so manual and launchd deployments keep
// their existing lifetime.
func watchSupervisorParent(ctx context.Context, cancel context.CancelFunc) {
	ticker := time.NewTicker(managedParentPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if os.Getppid() == 1 {
				log.Printf("event=worker_parent_exited")
				cancel()
				return
			}
		}
	}
}

// watchStandaloneParent does the same for a Worker that is not running under
// the LAN supervisor. The C listener has no graceful shutdown, so exiting here
// leaves only a stale socket, which the App removes before the next start.
func watchStandaloneParent() {
	ticker := time.NewTicker(managedParentPollInterval)
	defer ticker.Stop()
	for range ticker.C {
		if os.Getppid() == 1 {
			log.Printf("event=worker_parent_exited")
			os.Exit(0)
		}
	}
}
