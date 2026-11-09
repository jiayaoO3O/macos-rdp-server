// Package config validates the local P0 worker's explicit configuration.
package config

import (
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"rdp-server/internal/auth"
	"syscall"
)

type Config struct {
	Address      string `json:"address"`
	AllowLAN     bool   `json:"allow_lan"`
	Port         int    `json:"port"`
	Account      string `json:"account"`
	Enabled      bool   `json:"enabled"`
	TestPattern  bool   `json:"test_pattern"`
	Clipboard    bool   `json:"clipboard"`
	Certificate  string `json:"certificate"`
	Key          string `json:"key"`
	SAM          string `json:"sam"`
	AutoLAN      bool   `json:"-"`
	LANInterface string `json:"-"`
}

const DefaultPort = 3389

// PrivateFile rejects secrets that other accounts could read or replace.
// P0 requires a private parent owned by this process's UID. System deployment
// and hostile same-UID processes are outside this development-store boundary.
func PrivateFile(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || int(stat.Uid) != os.Geteuid() {
		return fmt.Errorf("%s must be an owned regular file with mode 0600", path)
	}
	dir, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return err
	}
	ds, ok := dir.Sys().(*syscall.Stat_t)
	if !ok || !dir.IsDir() || dir.Mode().Perm()&0077 != 0 || int(ds.Uid) != os.Geteuid() {
		return fmt.Errorf("%s must be a private owned directory", filepath.Dir(path))
	}
	return nil
}
func (c Config) Validate() error {
	if c.Address == "auto" {
		if !c.AllowLAN {
			return fmt.Errorf("address auto requires allow_lan=true")
		}
	} else {
		ip, err := netip.ParseAddr(c.Address)
		if err != nil || !ip.Is4() || (c.Address != "127.0.0.1" && (!c.AllowLAN || !ip.IsPrivate())) {
			return fmt.Errorf("address must be 127.0.0.1 or an explicitly enabled private IPv4; port must be 1024..65535")
		}
	}
	if c.Port < 1024 || c.Port > 65535 {
		return fmt.Errorf("address must be 127.0.0.1 or an explicitly enabled private IPv4; port must be 1024..65535")
	}
	name, err := auth.Principal(c.Account, "MACRDP")
	if err != nil || name != c.Account {
		return fmt.Errorf("account must be a lowercase bare MACRDP principal")
	}
	return nil
}
func Load(path string) (Config, error) {
	return load(path, DiscoverLANAddress)
}

func load(path string, discoverLAN func() (netip.Addr, string, error)) (Config, error) {
	var c Config
	if err := PrivateFile(path); err != nil {
		return c, err
	}
	f, err := os.Open(path)
	if err != nil {
		return c, err
	}
	defer f.Close()
	dec := json.NewDecoder(io.LimitReader(f, 65537))
	dec.DisallowUnknownFields()
	if err = dec.Decode(&c); err != nil {
		return c, err
	}
	var extra any
	if dec.Decode(&extra) != io.EOF {
		return c, fmt.Errorf("configuration must contain one JSON object")
	}
	if c.Port == 0 {
		c.Port = DefaultPort
	}
	if c.Address == "auto" {
		if !c.AllowLAN {
			return c, fmt.Errorf("address auto requires allow_lan=true")
		}
		c.AutoLAN = true
		if resolved := os.Getenv("RDP_WORKER_RESOLVED_ADDRESS"); resolved != "" {
			c.Address = resolved
		} else {
			address, iface, resolveErr := discoverLAN()
			if resolveErr != nil {
				return c, resolveErr
			}
			c.Address = address.String()
			c.LANInterface = iface
		}
	}
	if err = c.Validate(); err != nil {
		return c, err
	}
	for _, p := range []string{c.SAM, c.Key, c.Certificate} {
		if !filepath.IsAbs(p) {
			return c, fmt.Errorf("credential paths must be absolute")
		}
		if err = PrivateFile(p); err != nil {
			return c, err
		}
	}
	return c, nil
}
