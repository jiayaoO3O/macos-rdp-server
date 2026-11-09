// Package worker hosts a FreeRDP event loop in a dedicated process.
package worker

/*
#cgo CFLAGS: -I${SRCDIR}/../../.deps/install/include/freerdp3 -I${SRCDIR}/../../.deps/install/include/winpr3
#cgo LDFLAGS: -L${SRCDIR}/../../.deps/install/lib -lfreerdp-server3 -lfreerdp-client3 -lfreerdp3 -lwinpr3 -Wl,-rpath,${SRCDIR}/../../.deps/install/lib
#include <stdlib.h>
#include "native.h"
*/
import "C"

import (
	"fmt"
	"log"
	"rdp-server/internal/auth"
	"runtime"
	"sync"
	"unsafe"
)

var gate *auth.Gate
var serveMu sync.Mutex

//export goAuthorize
func goAuthorize(user, domain *C.char) (result C.ulonglong) {
	defer func() {
		if recover() != nil {
			log.Print("event=authorization_callback_panic result=denied")
			result = 0
		}
	}()
	if gate == nil {
		log.Print("event=authorization_denied reason=gate_unavailable")
		return 0
	}
	token := gate.Acquire(C.GoString(user), C.GoString(domain))
	if token == 0 {
		log.Print("event=authorization_denied")
		return 0
	}
	log.Print("event=authorized backend=authorized-session")
	return C.ulonglong(token)
}

//export goLeaseHeartbeat
func goLeaseHeartbeat(token C.ulonglong) {
	if gate == nil {
		return
	}
	gate.Heartbeat(uint64(token))
}

//export goRelease
func goRelease(token C.ulonglong) {
	defer func() {
		if recover() != nil {
			log.Print("event=release_callback_panic")
		}
	}()
	if gate != nil && gate.Release(uint64(token)) {
		log.Print("event=lease_released")
		return
	}
	// A peer whose lease was taken over after it went stale must not drop the
	// current owner's lease.
	log.Print("event=lease_release_ignored reason=not_owner")
}

func stringsC(values ...string) ([]*C.char, func()) {
	pointers := make([]*C.char, len(values))
	for i, v := range values {
		pointers[i] = C.CString(v)
	}
	return pointers, func() {
		for _, p := range pointers {
			C.free(unsafe.Pointer(p))
		}
	}
}

func Serve(address string, port int, cert, key, sam, agentSocket, account string, enabled, testPattern, clipboard bool) error {
	serveMu.Lock()
	defer serveMu.Unlock()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	gate = auth.NewGate(account, enabled)
	p, free := stringsC(address, cert, key, sam, agentSocket)
	defer free()
	testPatternFlag := C.int(0)
	if testPattern {
		testPatternFlag = 1
	}
	clipboardFlag := C.int(0)
	if clipboard {
		clipboardFlag = 1
	}
	if rc := C.rdp_serve(p[0], C.int(port), p[1], p[2], p[3], p[4], testPatternFlag, clipboardFlag); rc != 0 {
		return fmt.Errorf("FreeRDP worker stopped: %d", rc)
	}
	return nil
}

// Probe is a headless FreeRDP interoperability check, not Windows App acceptance.
func Probe(address string, port int, user, domain, password string, mode, width, height int) int {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	p, free := stringsC(address, user, domain, password)
	defer free()
	return int(C.rdp_probe(p[0], C.int(port), p[1], p[2], p[3], C.int(mode), C.int(width), C.int(height)))
}

// NTHash delegates to WinPR; it does not implement NTLM in Go.
func NTHash(password string) ([16]byte, error) {
	var hash [16]byte
	p := C.CString(password)
	defer C.free(unsafe.Pointer(p))
	if C.rdp_nt_hash(p, (*C.uchar)(unsafe.Pointer(&hash[0]))) == 0 {
		return hash, fmt.Errorf("WinPR NT hash failed")
	}
	return hash, nil
}