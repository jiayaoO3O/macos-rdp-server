// rdpctl currently exposes only the private development-store hash helper.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"rdp-server/internal/worker"
	"strings"
)

func main() {
	if len(os.Args) != 2 || os.Args[1] != "hash-stdin" {
		fmt.Fprintln(os.Stderr, "usage: rdpctl hash-stdin (private dev-init helper)")
		os.Exit(2)
	}
	password, err := bufio.NewReader(io.LimitReader(os.Stdin, 4097)).ReadString('\n')
	if err != nil || len(password) > 4096 || strings.ContainsRune(password, 0) {
		fmt.Fprintln(os.Stderr, "invalid password input")
		os.Exit(2)
	}
	hash, err := worker.NTHash(strings.TrimSuffix(password, "\n"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("%x\n", hash)
}
