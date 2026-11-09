// Package auth applies the service's account naming boundary after NLA.
package auth

import (
	"errors"
	"strings"
)

// Principal accepts bare names or MACRDP\\name. A separately supplied domain
// must also match; a prefix can never override an untrusted domain.
func Principal(user, domain string) (string, error) {
	invalid := errors.New("invalid RDP principal or domain")
	if domain != "" && !strings.EqualFold(domain, "MACRDP") {
		return "", invalid
	}
	if prefix, name, found := strings.Cut(user, `\`); found {
		if !strings.EqualFold(prefix, "MACRDP") {
			return "", invalid
		}
		user = name
	}
	if len(user) == 0 || len(user) > 64 {
		return "", invalid
	}
	for _, c := range user {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return "", invalid
		}
	}
	return strings.ToLower(user), nil
}
