package worker

import (
	"encoding/hex"
	"testing"
)

func TestWinPRHashKnownVector(t *testing.T) {
	hash, err := NTHash("password")
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(hash[:]) != "8846f7eaee8fb117ad06bdd830b7586c" {
		t.Fatal("NT hash differs from known vector")
	}
}
