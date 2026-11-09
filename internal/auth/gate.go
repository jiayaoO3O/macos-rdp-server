package auth

import (
	"sync"
	"time"
)

// LeaseStaleAfter is how long a held lease may go without a heartbeat before a
// new login may take it over. The owning peer heartbeats once per second while
// it is leased and activated, so a silent lease means the peer thread is wedged
// (for example a half-open TCP connection after a client network drop).
var LeaseStaleAfter = 30 * time.Second

// Gate owns the single active connection lease.
//
// The lease is a token: a peer only ever releases the token it acquired. If a
// peer wedges and its lease is taken over, the late release from the old peer is
// ignored instead of dropping the new owner's lease. Before 2026-11-07 the gate
// was a bare boolean, so one wedged peer denied every later login forever and
// the Windows client reported error 0x904 ("logon failed") to the user.
type Gate struct {
	mu         sync.Mutex
	name       string
	enabled    bool
	owner      uint64
	heartbeat  time.Time
	nextToken  uint64
	now        func() time.Time
	staleAfter time.Duration
}

func NewGate(name string, enabled bool) *Gate {
	return &Gate{name: name, enabled: enabled, now: time.Now, staleAfter: LeaseStaleAfter}
}

// Acquire returns a non-zero lease token, or 0 when the login is denied.
func (g *Gate) Acquire(user, domain string) uint64 {
	principal, err := Principal(user, domain)
	g.mu.Lock()
	defer g.mu.Unlock()
	if err != nil || !g.enabled || principal != g.name {
		return 0
	}
	if g.owner != 0 {
		if g.now().Sub(g.heartbeat) <= g.staleAfter {
			return 0
		}
		g.owner = 0 // stale lease taken over
	}
	g.nextToken++
	g.owner = g.nextToken
	g.heartbeat = g.now()
	return g.owner
}

// Heartbeat keeps the given lease alive; it ignores tokens that no longer own it.
func (g *Gate) Heartbeat(token uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if token != 0 && token == g.owner {
		g.heartbeat = g.now()
	}
}

// Release drops the lease when token owns it. It reports whether this call
// actually released the lease (false for a stale owner or an already free gate).
func (g *Gate) Release(token uint64) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if token == 0 || token != g.owner {
		return false
	}
	g.owner = 0
	return true
}

// Held reports whether a lease is currently owned.
func (g *Gate) Held() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.owner != 0
}
