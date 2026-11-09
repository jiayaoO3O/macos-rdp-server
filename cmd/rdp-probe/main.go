// rdp-probe is a headless development client. Credentials are read from stdin.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"rdp-server/internal/worker"
	"strings"
)

func main() {
	port := flag.Int("port", 3389, "loopback worker port")
	user := flag.String("user", "alice", "RDP account")
	domain := flag.String("domain", "MACRDP", "RDP domain")
	mode := flag.Int("mode", 0, "0=bitmap and input; 1=hold lease; 2=TLS without NLA; 8=GFX AVC420 decode")
	width := flag.Int("width", 800, "requested desktop width")
	height := flag.Int("height", 600, "requested desktop height")
	flag.Parse()
	password, err := bufio.NewReader(io.LimitReader(os.Stdin, 4097)).ReadString('\n')
	if err != nil || len(password) > 4096 {
		fmt.Fprintln(os.Stderr, "password must be a line of at most 4095 bytes on stdin")
		os.Exit(2)
	}
	os.Exit(worker.Probe("127.0.0.1", *port, *user, *domain, strings.TrimSuffix(password, "\n"), *mode, *width, *height))
}
