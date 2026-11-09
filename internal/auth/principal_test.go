package auth

import "testing"

func TestPrincipalDomainBoundary(t *testing.T) {
	for _, tc := range []struct {
		user, domain, want string
		ok                 bool
	}{
		{"alice", "MACRDP", "alice", true},
		{`MACRDP\Alice`, "", "alice", true},
		{"Alice", "macrdp", "alice", true},
		{"alice", "", "alice", true},
		{`EVIL\alice`, "MACRDP", "", false},
		{"alice", "EVIL", "", false},
		{`MACRDP\alice`, "EVIL", "", false},
		{"alice@EVIL", "MACRDP", "", false},
		{"", "MACRDP", "", false},
		{" alice", "MACRDP", "", false},
		{"alice:hash", "MACRDP", "", false},
	} {
		got, err := Principal(tc.user, tc.domain)
		if (err == nil) != tc.ok || got != tc.want {
			t.Errorf("Principal(%q,%q) = %q, %v; want %q ok=%v", tc.user, tc.domain, got, err, tc.want, tc.ok)
		}
	}
}
