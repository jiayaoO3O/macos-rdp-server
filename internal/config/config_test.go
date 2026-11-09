package config

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateFileBoundary(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "sam")
	if err := os.WriteFile(p, []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := PrivateFile(p); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, 0644); err != nil {
		t.Fatal(err)
	}
	if PrivateFile(p) == nil {
		t.Fatal("accepted world-readable credential")
	}
	if err := os.Chmod(p, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(p, link); err != nil {
		t.Fatal(err)
	}
	if PrivateFile(link) == nil {
		t.Fatal("accepted symlink credential")
	}
	if err := os.Chmod(dir, 0777); err != nil {
		t.Fatal(err)
	}
	if PrivateFile(p) == nil {
		t.Fatal("accepted replaceable credential in writable directory")
	}
}
func TestValidateLoopbackOnlyP0(t *testing.T) {
	for _, address := range []string{"0.0.0.0", "::", "192.168.1.1", "localhost"} {
		if (Config{Address: address, Port: 13389, Account: "alice"}).Validate() == nil {
			t.Fatalf("accepted %s", address)
		}
	}
	if err := (Config{Address: "127.0.0.1", Port: 13389, Account: "alice"}).Validate(); err != nil {
		t.Fatal(err)
	}
	if (Config{Address: "127.0.0.1", Port: 70000, Account: "alice"}).Validate() == nil {
		t.Fatal("accepted invalid port")
	}
}

func TestValidateExplicitPrivateLAN(t *testing.T) {
	for _, address := range []string{"10.0.0.250", "172.16.1.2", "192.168.1.2"} {
		c := Config{Address: address, Port: 3389, Account: "alice", AllowLAN: true}
		if err := c.Validate(); err != nil {
			t.Fatalf("private address %s rejected: %v", address, err)
		}
		c.AllowLAN = false
		if c.Validate() == nil {
			t.Fatalf("%s accepted without explicit LAN opt-in", address)
		}
	}
	for _, address := range []string{"0.0.0.0", "8.8.8.8", "169.254.1.1", "100.100.1.1", "localhost", "::1"} {
		if (Config{Address: address, Port: 3389, Account: "alice", AllowLAN: true}).Validate() == nil {
			t.Fatalf("unsafe address %s accepted", address)
		}
	}
}

func TestValidateAutoLANRequiresExplicitLANOptIn(t *testing.T) {
	if err := (Config{Address: "auto", Port: 3389, Account: "alice", AllowLAN: true}).Validate(); err != nil {
		t.Fatalf("auto LAN address rejected: %v", err)
	}
	if (Config{Address: "auto", Port: 3389, Account: "alice"}).Validate() == nil {
		t.Fatal("auto LAN address accepted without allow_lan")
	}
}

func TestSelectLANAddressPrefersRouteAndRejectsVirtualInterfaces(t *testing.T) {
	candidates := []lanCandidate{
		{name: "en0", index: 4, up: true, address: netip.MustParseAddr("10.0.0.10")},
		{name: "en1", index: 2, up: true, address: netip.MustParseAddr("192.168.1.22")},
		{name: "utun8", index: 1, up: true, address: netip.MustParseAddr("10.8.0.2")},
	}
	got, err := selectLANAddress(candidates, netip.MustParseAddr("10.0.0.10"))
	if err != nil || got.String() != "10.0.0.10" {
		t.Fatalf("selected %v, %v; want route address 10.0.0.10", got, err)
	}
	got, err = selectLANAddress(candidates, netip.MustParseAddr("203.0.113.1"))
	if err != nil || got.String() != "10.0.0.10" {
		t.Fatalf("fallback selected %v, %v; want physical LAN address", got, err)
	}
}

func TestSelectLANAddressFailsClosedWithoutPrivateInterface(t *testing.T) {
	for _, candidates := range [][]lanCandidate{
		{{name: "en0", index: 1, up: true, address: netip.MustParseAddr("169.254.1.2")}},
		{{name: "utun2", index: 1, up: true, address: netip.MustParseAddr("10.8.0.2")}},
		{{name: "en0", index: 1, up: false, address: netip.MustParseAddr("10.0.0.10")}},
	} {
		if address, err := selectLANAddress(candidates, netip.Addr{}); err == nil {
			t.Fatalf("selected unsafe LAN address %v", address)
		}
	}
}

func TestLoadResolvesAutoAddressFromLANDiscovery(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sam", "key.pem", "cert.pem"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(dir, "config.json")
	contents := `{"address":"auto","allow_lan":true,"account":"alice","enabled":true,"certificate":"` + filepath.Join(dir, "cert.pem") + `","key":"` + filepath.Join(dir, "key.pem") + `","sam":"` + filepath.Join(dir, "sam") + `"}`
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := load(path, func() (netip.Addr, string, error) {
		return netip.MustParseAddr("10.0.0.253"), "en0", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Address != "10.0.0.253" || !loaded.AutoLAN || loaded.LANInterface != "en0" {
		t.Fatalf("resolved auto config = %+v", loaded)
	}
}

func TestLoadDefaultsPortTo3389(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sam", "key.pem", "cert.pem"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	configPath := filepath.Join(dir, "config.json")
	config := `{"address":"127.0.0.1","account":"alice","enabled":true,"certificate":"` + filepath.Join(dir, "cert.pem") + `","key":"` + filepath.Join(dir, "key.pem") + `","sam":"` + filepath.Join(dir, "sam") + `"}`
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}

	loaded, err := Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Port != 3389 {
		t.Fatalf("default port = %d, want 3389", loaded.Port)
	}
	if loaded.TestPattern {
		t.Fatal("test pattern must not be enabled by default")
	}
	if loaded.Clipboard {
		t.Fatal("clipboard redirection must remain disabled by default until client acceptance")
	}
}

func TestLoadExplicitTestPatternMode(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sam", "key.pem", "cert.pem"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	configPath := filepath.Join(dir, "config.json")
	config := `{"address":"127.0.0.1","port":3389,"account":"alice","enabled":true,"test_pattern":true,"clipboard":true,"certificate":"` + filepath.Join(dir, "cert.pem") + `","key":"` + filepath.Join(dir, "key.pem") + `","sam":"` + filepath.Join(dir, "sam") + `"}`
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.TestPattern {
		t.Fatal("explicit test_pattern setting was ignored")
	}
	if !loaded.Clipboard {
		t.Fatal("explicit clipboard setting was ignored")
	}
}
