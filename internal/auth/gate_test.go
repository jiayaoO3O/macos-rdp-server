package auth

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestGateRejectsDisabledUnknownAndConcurrentAccounts(t *testing.T) {
	g := NewGate("alice", true)
	if g.Acquire("bob", "MACRDP") != 0 {
		t.Fatal("unknown principal authorized")
	}
	var accepted atomic.Int32
	var wg sync.WaitGroup
	for range 32 {
		wg.Go(func() {
			if g.Acquire("alice", "MACRDP") != 0 {
				accepted.Add(1)
			}
		})
	}
	wg.Wait()
	if accepted.Load() != 1 {
		t.Fatalf("accepted %d concurrent connections", accepted.Load())
	}
	if g.Acquire("alice", "MACRDP") != 0 {
		t.Fatal("second concurrent login authorized while a lease is held")
	}
	if NewGate("alice", false).Acquire("alice", "MACRDP") != 0 {
		t.Fatal("disabled account authorized")
	}
}

func TestGateTokenOwnershipAndRelease(t *testing.T) {
	g := NewGate("alice", true)
	token := g.Acquire("alice", "MACRDP")
	if token == 0 {
		t.Fatal("first login denied")
	}
	if !g.Held() {
		t.Fatal("lease not held after acquisition")
	}
	if g.Release(token + 1) {
		t.Fatal("a foreign token released the lease")
	}
	if !g.Held() {
		t.Fatal("lease dropped by a foreign token")
	}
	if !g.Release(token) {
		t.Fatal("owner token did not release the lease")
	}
	if g.Held() {
		t.Fatal("lease still held after owner release")
	}
	if g.Release(token) {
		t.Fatal("double release reported success")
	}
	if next := g.Acquire("alice", "MACRDP"); next == 0 || next == token {
		t.Fatalf("re-acquired lease token %d is not fresh (was %d)", next, token)
	}
}

func TestGateStaleLeaseIsTakenOver(t *testing.T) {
	now := time.Now()
	g := NewGate("alice", true)
	g.now = func() time.Time { return now }
	g.staleAfter = 10 * time.Second

	wedged := g.Acquire("alice", "MACRDP")
	if wedged == 0 {
		t.Fatal("first login denied")
	}
	// A live owner heartbeats, so its lease survives beyond the stale window.
	for i := 0; i < 5; i++ {
		now = now.Add(5 * time.Second)
		g.Heartbeat(wedged)
		if g.Acquire("alice", "MACRDP") != 0 {
			t.Fatal("a heartbeating lease was taken over")
		}
	}
	// Now the owner stops heartbeating (wedged peer): a new login takes over.
	now = now.Add(11 * time.Second)
	takeover := g.Acquire("alice", "MACRDP")
	if takeover == 0 {
		t.Fatal("stale lease was not taken over; a wedged peer would lock out logins forever")
	}
	// The stale peer's late release must not drop the new owner's lease.
	if g.Release(wedged) {
		t.Fatal("stale owner released the current lease")
	}
	if !g.Held() {
		t.Fatal("current lease dropped by the stale owner")
	}
	// The stale peer's late heartbeat must not refresh the current lease either.
	// At 47 s the current owner's last heartbeat is 11 s old (> staleAfter), so a
	// takeover must be allowed; if the foreign heartbeat had been honoured the
	// lease would look 2 s old and the login would be denied.
	now = now.Add(9 * time.Second)
	g.Heartbeat(wedged)
	now = now.Add(2 * time.Second)
	if g.Acquire("alice", "MACRDP") == 0 {
		t.Fatal("stale heartbeat kept a foreign lease alive")
	}
}

func TestGateHeartbeatIgnoresZeroAndUnheldTokens(t *testing.T) {
	g := NewGate("alice", true)
	g.Heartbeat(0) // must not panic or create an owner
	if g.Held() {
		t.Fatal("zero-token heartbeat created a lease")
	}
	g.Heartbeat(42)
	if g.Held() {
		t.Fatal("unknown-token heartbeat created a lease")
	}
}
