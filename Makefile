export GOCACHE := $(CURDIR)/.cache/go-build

# Deployment policy: the bundle must run on macOS 26 (this dev machine runs a
# newer macOS). SwiftPM already targets macOS 14; keep the Go/cgo helpers at
# the same minimum and normalize bundled third-party dylibs at packaging time.
export MACOSX_DEPLOYMENT_TARGET := 14.0
export CGO_CFLAGS := -mmacosx-version-min=14.0
export CGO_LDFLAGS := -mmacosx-version-min=14.0

.PHONY: deps build build-avc420-worker test test-protocol test-windows-app-smoke test-agent-launchd test-performance-baseline test-agent-ipc-wire test-worker-auto-lan test-gfx-session test-avc-encoder test-avc420-build test-avc420-gfx-probe test-freerdp-no-pipe2 test-freerdp-sdk-selection check agent-build agent-app agent-check app-build app-dmg test-app test-app-bundle test-virtual-display

deps:
	sh scripts/build-freerdp.sh

build:
	go build -o bin/ ./cmd/...

build-avc420-worker:
	mkdir -p bin
	go build -tags avc420 -o bin/rdp-worker-avc420 ./cmd/rdp-worker

test:
	go test -race ./...

test-protocol: build
	python3 scripts/test-protocol.py

test-windows-app-smoke:
	python3 scripts/test-windows-app-smoke.py

test-agent-launchd:
	python3 scripts/test-agent-launchd.py

test-performance-baseline:
	python3 scripts/test-performance-baseline.py

test-agent-ipc-wire:
	python3 scripts/test-agent-ipc-wire.py

test-worker-auto-lan: build
	python3 scripts/test-worker-auto-lan.py

test-gfx-session:
	python3 scripts/test-gfx-session.py

test-freerdp-no-pipe2:
	python3 scripts/test-freerdp-no-pipe2.py

test-freerdp-sdk-selection:
	python3 scripts/test-freerdp-sdk-selection.py

test-avc-encoder:
	python3 scripts/test-avc-encoder.py

test-avc420-build: build-avc420-worker
	go test -tags avc420 ./internal/worker

test-avc420-gfx-probe: build build-avc420-worker
	RDP_TEST_GFX=1 RDP_ENABLE_AVC420=1 RDP_TEST_WORKER_BINARY="$(CURDIR)/bin/rdp-worker-avc420" DYLD_LIBRARY_PATH="$(CURDIR)/.deps/install-h264/lib$${DYLD_LIBRARY_PATH:+:$${DYLD_LIBRARY_PATH}}" python3 scripts/test-protocol.py ProtocolTest.test_12_gfx_avc420_client_probe

check: test test-gfx-session test-avc-encoder
	go vet ./...

agent-build:
	swift build -c release --package-path native/macos
	cp native/macos/.build/release/rdp-agent bin/rdp-agent

agent-app: agent-build
	python3 scripts/package-agent-app.py

test-virtual-display:
	swift build -c release --package-path native/macos
	python3 scripts/test-virtual-display-integration.py

# Menu bar app (RDPServer.app) build + DMG packaging. These never overwrite the
# deployed bin/ artifacts: the bundled app lives in dist/ (see
# docs/DESIGN-2026-11-08-app-packaging.md).
app-build:
	swift build -c release --package-path native/macos

app-dmg: app-build
	python3 scripts/package-app-dmg.py

test-app:
	python3 scripts/test-app-core.py

test-app-bundle:
	python3 scripts/test-app-bundle.py

agent-check:
	mkdir -p native/macos/.build
	swiftc native/macos/Sources/MacAgentCore/PermissionSnapshot.swift native/macos/Sources/MacAgentCore/CaptureProgress.swift native/macos/Sources/MacAgentCore/AgentStreamDuration.swift native/macos/Sources/MacAgentCore/AgentInputAudit.swift native/macos/Sources/MacAgentCore/CaptureExclusion.swift native/macos/Sources/MacAgentCore/DisplayCoordinateMapper.swift native/macos/Sources/MacAgentCore/DisplayModeMatcher.swift native/macos/Sources/MacAgentCore/AgentIPCMessage.swift native/macos/Sources/MacAgentCore/ClipboardFileTransfer.swift native/macos/Sources/MacAgentCore/ClipboardFileStaging.swift native/macos/Sources/MacAgentCore/AgentFrameAssembler.swift native/macos/Sources/MacAgentCore/AgentUnixSocket.swift native/macos/Sources/MacAgentCore/MacKeyMap.swift native/macos/Sources/MacAgentCore/DisplayPixelSize.swift native/macos/Sources/MacAgentCore/SnapshotPacing.swift native/macos/Sources/MacAgentCore/CaptureTiming.swift native/macos/Sources/MacAgentCore/CaptureSizeRequest.swift native/macos/Sources/MacAgentCore/CaptureGeometry.swift native/macos/Sources/MacAgentCore/DisplayLayout.swift native/macos/Sources/MacAgentCore/CapturePixelConverter.swift native/macos/Sources/MacAgentCore/AgentFrameDeltaEncoder.swift native/macos/Sources/MacAgentCore/VirtualDisplaySession.swift native/macos/Sources/MacAgentCore/KeyboardInputState.swift native/macos/Sources/MacAgentCore/MouseClickState.swift native/macos/Tests/MacAgentCoreTests/PermissionSnapshotTests.swift native/macos/Tests/MacAgentCoreTests/DisplayModeTests.swift native/macos/Tests/MacAgentCoreTests/ClipboardFileTransferTests.swift native/macos/Tests/MacAgentCoreTests/VirtualDisplayTests.swift native/macos/Tests/MacAgentCoreTests/KeyboardInputStateTests.swift native/macos/Tests/MacAgentCoreTests/MouseClickStateTests.swift -o native/macos/.build/permission-tests
	native/macos/.build/permission-tests
