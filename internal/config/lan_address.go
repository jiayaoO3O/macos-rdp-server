package config

import (
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strings"
)

type lanCandidate struct {
	name     string
	index    int
	up       bool
	loopback bool
	address  netip.Addr
}

// DiscoverLANAddress selects a private IPv4 address on an active physical LAN
// interface. It never falls back to a wildcard or public address.
func DiscoverLANAddress() (netip.Addr, string, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return netip.Addr{}, "", fmt.Errorf("list network interfaces: %w", err)
	}
	candidates := make([]lanCandidate, 0)
	for _, iface := range interfaces {
		up := iface.Flags&net.FlagUp != 0
		loopback := iface.Flags&net.FlagLoopback != 0
		addresses, addrErr := iface.Addrs()
		if addrErr != nil {
			continue
		}
		for _, address := range addresses {
			prefix, parseErr := netip.ParsePrefix(address.String())
			if parseErr != nil {
				continue
			}
			candidates = append(candidates, lanCandidate{
				name: iface.Name, index: iface.Index, up: up, loopback: loopback,
				address: prefix.Addr().Unmap(),
			})
		}
	}
	selected, err := selectLANAddress(candidates, defaultRouteIPv4())
	if err != nil {
		return netip.Addr{}, "", err
	}
	for _, candidate := range candidates {
		if candidate.address == selected && eligibleLANCandidate(candidate) {
			return selected, candidate.name, nil
		}
	}
	return netip.Addr{}, "", fmt.Errorf("selected LAN address disappeared")
}

func defaultRouteIPv4() netip.Addr {
	// A UDP connect only asks the kernel to select a route; it sends no packet.
	conn, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(192, 0, 2, 1), Port: 9})
	if err != nil {
		return netip.Addr{}
	}
	defer conn.Close()
	local, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return netip.Addr{}
	}
	address, ok := netip.AddrFromSlice(local.IP)
	if !ok {
		return netip.Addr{}
	}
	return address.Unmap()
}

func selectLANAddress(candidates []lanCandidate, routeAddress netip.Addr) (netip.Addr, error) {
	eligible := make([]lanCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		if eligibleLANCandidate(candidate) {
			eligible = append(eligible, candidate)
		}
	}
	if len(eligible) == 0 {
		return netip.Addr{}, fmt.Errorf("no active private IPv4 LAN interface found")
	}
	for _, candidate := range eligible {
		if routeAddress.IsValid() && candidate.address == routeAddress {
			return candidate.address, nil
		}
	}
	sort.SliceStable(eligible, func(i, j int) bool {
		left, right := lanInterfaceRank(eligible[i].name), lanInterfaceRank(eligible[j].name)
		if left != right {
			return left < right
		}
		return eligible[i].index < eligible[j].index
	})
	return eligible[0].address, nil
}

func eligibleLANCandidate(candidate lanCandidate) bool {
	if !candidate.up || candidate.loopback || !candidate.address.IsValid() ||
		!candidate.address.Is4() || !candidate.address.IsPrivate() || candidate.address.IsLinkLocalUnicast() {
		return false
	}
	name := strings.ToLower(candidate.name)
	for _, virtualPrefix := range []string{"utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "p2p", "tap", "tun", "vmenet"} {
		if strings.HasPrefix(name, virtualPrefix) {
			return false
		}
	}
	return true
}

func lanInterfaceRank(name string) int {
	name = strings.ToLower(name)
	if name == "en0" {
		return 0
	}
	if strings.HasPrefix(name, "en") {
		return 1
	}
	return 2
}
