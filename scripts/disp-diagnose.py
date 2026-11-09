#!/usr/bin/env python3
"""Isolated MS-RDPEDISP window-resize diagnostic for Microsoft Windows App 11.4.4.

Purpose (Issue 1, 2026-11-08): find out why the Windows App client does not send
a DISPLAY_CONTROL_PDU_TYPE_MONITOR_LAYOUT PDU when the user resizes the session
window against our worker, even though the server opens the
Microsoft::Windows::RDS::DisplayControl DVC and sends DisplayControlCaps.

What it does:
  1. starts a throwaway worker on the private LAN address of this Mac (random
     port, --test-pattern backend so no Agent is needed) with a temporary
     config/SAM/self-signed certificate under /tmp;
  2. creates a temporary Windows App bookmark ("rdp-disp-test" by default) via
     the app's scripting CLI and prints exact user steps (connect, resize the
     window 2-3 times, disconnect);
  3. captures ``log stream --info --predicate 'process == "Windows App"'``
     live, because Windows App info-level entries are ephemeral;
  4. on exit correlates the worker DISP audit lines (disp_channel_*,
     disp_caps_sent, disp_monitor_layout) with the client's own DISP log lines
     and prints a verdict;
  5. deletes the temporary bookmark and the temporary credentials.

The live production worker on port 3389 and the user's existing bookmarks are
never modified. The temporary SAM password only exists for one run.

Usage:
    scripts/disp-diagnose.py            # interactive user test
    scripts/disp-diagnose.py --self-test  # harness self-check, no GUI needed

Exit codes: 0 diagnosis completed, 1 preflight/harness error, 2 user interrupted.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_APP = Path("/Applications/Windows App.app/Contents/MacOS/Windows App")
RDPCTL = ROOT / "bin/rdpctl"
LOG_BIN = Path("/usr/bin/log")
OPENSSL_CANDIDATES = (
    Path("/opt/homebrew/opt/openssl@3/bin/openssl"),
    Path(shutil.which("openssl") or ""),
)

ACCOUNT = "alice"
DOMAIN = "MACRDP"
USERNAME = f"{DOMAIN}\\{ACCOUNT}"
DEFAULT_FRIENDLY_NAME = "rdp-disp-test"

# The exact worker audit lines the patched DISP diagnostics emit (see
# docs/DIAGNOSIS-2026-11-08-disp-window-resize.md). Kept as regexes so appended
# fields keep working when the diagnostics evolve.
WORKER_PATTERNS = {
    "authorized": re.compile(r"event=authorized\b"),
    "disp_channel_id_assigned": re.compile(r"event=disp_channel_id_assigned\b id=(\d+)"),
    "disp_channel_opened_ok": re.compile(r"event=disp_channel_opened result=0\b"),
    "disp_channel_opened_failed": re.compile(r"event=disp_channel_opened result=1\b"),
    "disp_caps_sent": re.compile(r"event=disp_caps_sent result=(\d+)"),
    "disp_monitor_layout": re.compile(
        r"event=disp_monitor_layout requested=(\d+)x(\d+) monitors=(\d+)"),
    "disp_channel_closed": re.compile(r"event=disp_channel_closed\b"),
    "peer_reactivate": re.compile(r"event=peer_reactivate\b"),
    "peer_resize_ignored": re.compile(r"event=peer_resize_ignored\b"),
    "peer_loop_ended": re.compile(r"event=peer_loop_ended\b"),
    "lease_released": re.compile(r"event=lease_released\b"),
}

# Lines from the Windows App unified log that are relevant to the DISP question.
CLIENT_PATTERNS = (
    re.compile(r"Display\s*Control", re.IGNORECASE),
    re.compile(r"SendMonitorLayout", re.IGNORECASE),
    re.compile(r"MonitorLayout", re.IGNORECASE),
    re.compile(r"dynamic\s*resolution", re.IGNORECASE),
    re.compile(r"DynamicResolution", re.IGNORECASE),
    re.compile(r"RdpDisplayControl", re.IGNORECASE),
    re.compile(r"dvcStats", re.IGNORECASE),
    re.compile(r"Microsoft::Windows::RDS::DisplayControl"),
)

MAX_LINES_IN_REPORT = 80


class HarnessError(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"[disp-diagnose] {message}", flush=True)


def run(command: list[str], *, input_text: str | None = None, timeout: float = 60,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, input=input_text, text=True, capture_output=True,
                          timeout=timeout, env=env)


RFC1918_NETWORKS = tuple(ipaddress.ip_network(net) for net in
                         ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))


def is_private_lan_ipv4(address: str) -> bool:
    """Match Go's netip.Addr.IsPrivate() accepted by worker config.Validate."""
    try:
        parsed = ipaddress.IPv4Address(address)
    except ValueError:
        return False
    return any(parsed in network for network in RFC1918_NETWORKS)


def local_lan_ipv4_addresses() -> list[str]:
    """Return RFC1918 IPv4 addresses assigned to this Mac (ifconfig based).

    A UDP-route probe can select a VPN/benchmark interface (e.g. 198.18.0.1) that
    Go's netip.IsPrivate() rejects, so enumerate real interface addresses and
    only accept RFC1918 ones.
    """
    try:
        completed = run(["/sbin/ifconfig"], timeout=15)
    except (subprocess.TimeoutExpired, OSError) as error:
        raise HarnessError(f"ifconfig failed: {error}") from error
    addresses: list[str] = []
    for match in re.finditer(r"\binet (\d{1,3}(?:\.\d{1,3}){3})\b", completed.stdout):
        address = match.group(1)
        if address == "127.0.0.1":
            continue
        if is_private_lan_ipv4(address) and address not in addresses:
            addresses.append(address)
    return addresses


def detect_lan_address() -> str:
    """Return a RFC1918 LAN IPv4 address that the Windows App can reach."""
    candidates = local_lan_ipv4_addresses()
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise HarnessError(
            "no RFC1918 IPv4 address found on this Mac; pass --address explicitly")
    raise HarnessError(
        "multiple private LAN addresses found: " + ", ".join(candidates) +
        "; pass --address explicitly")


def reserve_port(address: str) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
        reservation.bind((address, 0))
        return reservation.getsockname()[1]


def find_openssl() -> Path:
    for candidate in OPENSSL_CANDIDATES:
        if candidate and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise HarnessError("openssl not found (expected /opt/homebrew/opt/openssl@3/bin/openssl)")


def find_worker_binary(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
    elif os.environ.get("RDP_TEST_WORKER_BINARY"):
        path = Path(os.environ["RDP_TEST_WORKER_BINARY"])
    else:
        diagnostics_binary = Path("/tmp/rdp-worker-disp")
        path = diagnostics_binary if diagnostics_binary.is_file() else ROOT / "bin/rdp-worker"
    if not path.is_file() or not os.access(path, os.X_OK):
        raise HarnessError(f"worker binary not executable: {path}")
    return path


def windows_app_cli(args: list[str], timeout: float = 60) -> subprocess.CompletedProcess[str]:
    """Run ``Windows App --script ...`` without touching any live session."""
    if not WINDOWS_APP.is_file():
        raise HarnessError(f"Windows App not found at {WINDOWS_APP}")
    return run([str(WINDOWS_APP), "--script", *args], timeout=timeout)


def list_bookmarks() -> dict[str, str]:
    """Return {friendly name: bookmark id} from ``--script bookmark list``."""
    completed = windows_app_cli(["bookmark", "list"])
    bookmarks: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        match = re.match(r'"(.+)",\s*([0-9A-Fa-f-]{8,})$', line.strip())
        if match:
            bookmarks[match.group(1)] = match.group(2)
    return bookmarks


def export_bookmark(bookmark_id: str) -> str:
    return windows_app_cli(["bookmark", "export", bookmark_id]).stdout


def delete_bookmark(bookmark_id: str) -> bool:
    completed = windows_app_cli(["bookmark", "delete", bookmark_id])
    if completed.returncode != 0:
        return False
    return bookmark_id not in list_bookmarks().values()


def create_bookmark(bookmark_id: str, friendly_name: str, hostname: str,
                    password: str) -> None:
    completed = windows_app_cli([
        "bookmark", "write", bookmark_id,
        "--hostname", hostname,
        "--friendlyname", friendly_name,
        "--username", USERNAME,
        "--password", password,
        "--dynamicdisplay", "true",
        "--scaling", "false",
        "--fullscreen", "false",
        "--resolution", "1280 720",
    ])
    if completed.returncode != 0:
        raise HarnessError(
            "failed to create the temporary bookmark: "
            f"rc={completed.returncode} stdout={completed.stdout!r} "
            f"stderr={completed.stderr!r}")
    if bookmark_id not in list_bookmarks().values():
        raise HarnessError("temporary bookmark was not stored by Windows App")


class LogStream:
    """Live ``log stream --info`` capture for the Windows App process."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.error_path = path.with_suffix(".stderr.txt")
        self.process: subprocess.Popen[bytes] | None = None
        self.out = None
        self.err = None
        self.started = 0.0

    def start(self) -> None:
        if not LOG_BIN.is_file():
            raise HarnessError(f"log(1) not found at {LOG_BIN}")
        self.out = open(self.path, "wb")
        self.err = open(self.error_path, "wb")
        self.process = subprocess.Popen(
            [str(LOG_BIN), "stream", "--info", "--style", "compact",
             "--predicate", 'process == "Windows App"'],
            stdout=self.out, stderr=self.err)
        self.started = time.monotonic()
        time.sleep(1.5)
        if self.process.poll() is not None:
            self.stop()
            raise HarnessError(
                "log stream exited immediately; stderr=" + self.error_text())

    def error_text(self) -> str:
        try:
            return self.error_path.read_text(errors="replace").strip()
        except OSError:
            return ""

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process = None
        for handle in (self.out, self.err):
            try:
                if handle is not None:
                    handle.close()
            except OSError:
                pass
        self.out = self.err = None

    def text(self) -> str:
        try:
            return self.path.read_text(errors="replace")
        except OSError:
            return ""


class Worker:
    """Isolated test-pattern worker with temporary credentials under /tmp."""

    def __init__(self, binary: Path, directory: Path, address: str, port: int,
                 transport_dump: bool) -> None:
        self.binary = binary
        self.directory = directory
        self.address = address
        self.port = port
        self.transport_dump = transport_dump
        self.log_path = directory / "worker.log"
        self.password = secrets.token_hex(12)
        self.process: subprocess.Popen[bytes] | None = None
        self.log_handle = None

    @property
    def hostname(self) -> str:
        return f"{self.address}:{self.port}"

    def prepare(self) -> None:
        directory = self.directory
        os.chmod(directory, 0o700)

        completed = run([str(RDPCTL), "hash-stdin"], input_text=self.password + "\n",
                        timeout=30)
        nt_hash = completed.stdout.strip()
        if not re.fullmatch(r"[0-9a-f]{32}", nt_hash):
            raise HarnessError(f"rdpctl hash-stdin failed: {completed.stderr!r}")

        sam = directory / "sam"
        sam.write_text(f"{ACCOUNT}:{DOMAIN}::{nt_hash}:\n")
        os.chmod(sam, 0o600)

        openssl = find_openssl()
        key, cert = directory / "key.pem", directory / "cert.pem"
        completed = run([
            str(openssl), "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "2",
            "-subj", "/CN=rdp-disp-test",
            "-addext", f"subjectAltName=IP:{self.address},DNS:localhost",
        ], timeout=120)
        if completed.returncode != 0:
            raise HarnessError(f"openssl self-signed certificate failed: {completed.stderr!r}")
        os.chmod(key, 0o600)
        os.chmod(cert, 0o600)

        config = {
            "address": self.address,
            "allow_lan": True,
            "port": self.port,
            "account": ACCOUNT,
            "enabled": True,
            "test_pattern": True,
            "clipboard": False,
            "certificate": str(cert),
            "key": str(key),
            "sam": str(sam),
        }
        config_path = directory / "config.json"
        config_path.write_text(json.dumps(config) + "\n")
        os.chmod(config_path, 0o600)

    def env(self) -> dict[str, str]:
        environment = dict(os.environ)
        environment.update({
            "WLOG_LEVEL": "DEBUG",
            # WinPR requires <logger>:<LEVEL>; a bare logger tag aborts the worker.
            "WLOG_FILTER": "com.freerdp.channels.rdpedisp.server:DEBUG",
            "RDP_DISP_DEBUG": "1",
        })
        if self.transport_dump:
            environment["RDP_TRANSPORT_DUMP"] = str(self.directory / "transport.dump")
        return environment

    def start(self) -> None:
        self.log_handle = open(self.log_path, "wb")
        self.process = subprocess.Popen(
            [str(self.binary), "-config", str(self.directory / "config.json"),
             "-agent-socket", str(self.directory / "agent.sock")],
            stdout=self.log_handle, stderr=subprocess.STDOUT, env=self.env())
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise HarnessError("test worker exited before listening:\n" + self.text()[-3000:])
            if "event=listening" in self.text():
                time.sleep(0.3)  # let the listener accept connections
                return
            time.sleep(0.05)
        raise HarnessError("test worker did not report event=listening:\n" + self.text()[-3000:])

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process = None
        if self.log_handle is not None:
            try:
                self.log_handle.close()
            except OSError:
                pass
            self.log_handle = None

    def text(self) -> str:
        try:
            return self.log_path.read_text(errors="replace")
        except OSError:
            return ""


def wait_for_enter(timeout_seconds: float, started: float) -> bool:
    """Wait until the user presses Enter or the timeout expires."""
    if not sys.stdin.isatty():
        log("stdin is not a TTY; waiting for the timeout instead of Enter")
        remaining = max(0.0, timeout_seconds - (time.monotonic() - started))
        time.sleep(remaining)
        return False
    import select
    while True:
        remaining = timeout_seconds - (time.monotonic() - started)
        if remaining <= 0:
            print()
            log(f"timeout ({int(timeout_seconds)}s) reached")
            return False
        ready, _, _ = select.select([sys.stdin], [], [], min(remaining, 1.0))
        if ready:
            sys.stdin.readline()
            return True


def worker_summary(worker_text: str) -> dict:
    """Extract the DISP audit sequence and counts from the worker log."""
    lines = [line.rstrip("\n") for line in worker_text.splitlines()
             if any(pattern.search(line) for pattern in WORKER_PATTERNS.values())]
    counts = {name: sum(1 for line in lines if pattern.search(line))
              for name, pattern in WORKER_PATTERNS.items()}
    return {"lines": lines, "counts": counts}


def client_summary(client_text: str) -> dict:
    """Extract DISP-relevant Windows App log lines."""
    interesting = []
    for line in client_text.splitlines():
        if "Filtering the log data" in line:
            continue
        if any(pattern.search(line) for pattern in CLIENT_PATTERNS):
            interesting.append(line)
    return {"lines": interesting}


def verdict(worker: dict, client: dict) -> tuple[str, list[str]]:
    """Return (final verdict, supporting observations)."""
    counts = worker["counts"]
    observations: list[str] = []
    authorized = counts["authorized"] > 0
    opened_ok = counts["disp_channel_opened_ok"] > 0
    layout = counts["disp_monitor_layout"]
    reactivate = counts["peer_reactivate"]
    caps_ok = counts["disp_caps_sent"] > 0
    client_caps = any(re.search(r"Received Display Control Caps", line, re.IGNORECASE)
                      for line in client["lines"])
    client_layout_change = any(re.search(r"Received monitor layout change", line,
                                         re.IGNORECASE)
                               for line in client["lines"])
    client_send = any(re.search(r"SendMonitorLayoutPdu", line)
                      for line in client["lines"])
    client_validate_failed = any(re.search(r"ValidateDisplayControlMonitorLayout failed", line)
                                 for line in client["lines"])
    client_unsupported = any(re.search(r"OnServerSupportsDynamicResolution", line)
                             for line in client["lines"])

    observations.append(f"worker authorized={authorized} disp_open_ok={opened_ok} "
                        f"caps_sent={caps_ok} monitor_layout={layout} "
                        f"reactivate={reactivate}")
    observations.append(f"client log: caps_received={client_caps} "
                        f"layout_change_received={client_layout_change} "
                        f"send_monitor_layout_logged={client_send} "
                        f"validate_layout_failed={client_validate_failed} "
                        f"support_checkpoint_seen={client_unsupported}")

    if not authorized:
        return ("NOT TESTED: no RDP session reached the isolated test worker "
                "(no event=authorized). The Windows App never connected, or the "
                "bookmark was not used; rerun and click the bookmark before "
                "pressing Enter.", observations)
    if not opened_ok:
        return ("CLIENT-SIDE: the session connected but the Windows App never "
                "opened the Microsoft::Windows::RDS::DisplayControl DVC (worker "
                "DISP channel was not opened). The client did not enable dynamic "
                "resolution for this connection -> bookmark/setting issue, not a "
                "server DISP bug.", observations)
    if layout > 0 and reactivate > 0:
        return ("SUCCESS: isolated window-resize auto-resolution works - the "
                "client sent a DISP monitor layout and the worker reactivated at "
                "the requested size. The production problem must be a setting or "
                "an environment difference (compare bookmark properties).",
                observations)
    if layout > 0 and reactivate == 0:
        return ("SERVER BUG: the worker received a DISP monitor layout but never "
                "reactivated; inspect event=peer_resize_ignored / "
                "event=peer_reactivate in worker.log.", observations)
    if client_send:
        return ("CHANNEL/TRANSPORT ISSUE: the client logged a SendMonitorLayoutPdu "
                "attempt but the worker received no monitor layout. The client "
                "accepted the server caps (see client caps line); investigate "
                "channel state/transport (worker disp_channel_closed and "
                "disp_channel_id_assigned lines show the channel lifetime).",
                observations)
    if client_layout_change:
        return ("CLIENT PASSED ITS GATES, RDP LAYER DID NOT SEND: the client "
                "logged 'Received monitor layout change' after the resize but "
                "never logged SendMonitorLayoutPdu and the worker saw nothing. "
                "The DISP channel/caps state was not usable at that moment "
                "(client-side); the two log timestamps decide whether the "
                "channel had been closed.", observations)
    if client_caps:
        return ("CLIENT-SIDE GATE CLOSED: the client received DisplayControlCaps "
                "but, even after window resize, never logged 'Received monitor "
                "layout change' nor SendMonitorLayoutPdu, and the worker never "
                "received a layout. updateScreen() returned through its silent "
                "no-op path: one of dynamicResolutionEnabled / "
                "dynamicResolutionSupported / scalingEnabled / isMultipleMonitors "
                "/ railMode / layouts.count was false (see static analysis in "
                "docs/DIAGNOSIS-2026-11-08-disp-window-resize.md). This is a "
                "client-side setting/state issue, not a server DISP bug.",
                observations)
    return ("INCONCLUSIVE: worker opened DISP and sent caps, but no client-side "
            "DISP log line was captured. Re-run (info-level client logs are "
            "ephemeral and the stream must be up before the window is resized) "
            "and keep the session window open while resizing.", observations)


def print_section(title: str) -> None:
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)


def print_lines(lines: list[str], limit: int = MAX_LINES_IN_REPORT) -> None:
    if not lines:
        print("  (none)")
        return
    for line in lines[:limit]:
        print("  " + line)
    if len(lines) > limit:
        print(f"  ... {len(lines) - limit} more lines in the saved logs")


def cleanup_credentials(directory: Path) -> None:
    """Remove temporary secret material; keep non-secret diagnostic logs."""
    for name in ("sam", "config.json", "key.pem", "cert.pem"):
        path = directory / name
        try:
            if path.exists():
                path.unlink()
        except OSError:
            pass


def preflight(worker_binary: Path) -> None:
    problems = []
    if not WINDOWS_APP.is_file():
        problems.append(f"Windows App missing: {WINDOWS_APP}")
    if not RDPCTL.is_file():
        problems.append(f"rdpctl missing: {RDPCTL}")
    try:
        find_openssl()
    except HarnessError as error:
        problems.append(str(error))
    if not LOG_BIN.is_file():
        problems.append(f"log(1) missing: {LOG_BIN}")
    if not worker_binary.is_file():
        problems.append(f"worker binary missing: {worker_binary}")
    if problems:
        raise HarnessError("preflight failed:\n  " + "\n  ".join(problems))


def self_test(worker_binary: Path, address: str) -> int:
    """Validate the harness without requiring user GUI interaction."""
    log("self-test: preflight")
    preflight(worker_binary)
    directory = Path(tempfile.mkdtemp(prefix="disp-diagnose-selftest-", dir="/tmp"))
    worker = Worker(worker_binary, directory, address, reserve_port(address),
                    transport_dump=False)
    bookmark_id = str(uuid.uuid4()).upper()
    created = False
    try:
        worker.prepare()
        worker.start()
        log(f"self-test: worker listening on {worker.hostname}")

        stream = LogStream(directory / "windows-app-self-test.log")
        stream.start()
        log("self-test: log stream up")
        stream.stop()

        existing = list_bookmarks()
        if DEFAULT_FRIENDLY_NAME in existing:
            delete_bookmark(existing[DEFAULT_FRIENDLY_NAME])
        create_bookmark(bookmark_id, DEFAULT_FRIENDLY_NAME, worker.hostname,
                        worker.password)
        created = True
        exported = export_bookmark(bookmark_id)
        checks = {
            "bookmark stored": bookmark_id in list_bookmarks().values(),
            "hostname has random port": f":{worker.port}" in exported,
            "dynamic resolution on": "dynamic resolution:i:1" in exported,
            "username MACRDP\\alice": "username:s:MACRDP\\alice" in exported,
        }
        for label, ok in checks.items():
            log(f"self-test: {label}: {'PASS' if ok else 'FAIL'}")
        if not all(checks.values()):
            print(exported)
            return 1
        log("self-test: PASS (worker + log stream + bookmark lifecycle)")
        return 0
    finally:
        try:
            if created:
                delete_bookmark(bookmark_id)
                log("self-test: temporary bookmark deleted")
        finally:
            worker.stop()
            cleanup_credentials(directory)
            if os.environ.get("RDP_DISP_KEEP_TEMP") != "1":
                shutil.rmtree(directory, ignore_errors=True)
                log("self-test: temp directory removed")
            else:
                log(f"self-test: logs kept in {directory}")


def interactive(args: argparse.Namespace, worker_binary: Path, address: str) -> int:
    preflight(worker_binary)
    directory = Path(tempfile.mkdtemp(prefix="disp-diagnose-", dir="/tmp"))
    worker = Worker(worker_binary, directory, address,
                    args.port or reserve_port(address),
                    transport_dump=args.transport_dump)
    stream = LogStream(directory / "windows-app.log")
    bookmark_id = str(uuid.uuid4()).upper()
    bookmark_created = False
    previous_sigint = None

    def handle_sigint(signum, frame):  # noqa: ARG001 - signal handler signature
        raise KeyboardInterrupt

    previous_sigint = signal.signal(signal.SIGINT, handle_sigint)

    try:
        log("preparing isolated test worker (temp config/SAM/certificate in /tmp)")
        worker.prepare()
        worker.start()
        log(f"test worker listening on {worker.hostname} (test pattern, isolated)")

        existing = list_bookmarks()
        if DEFAULT_FRIENDLY_NAME in existing:
            log(f"removing stale temporary bookmark {DEFAULT_FRIENDLY_NAME!r} "
                f"({existing[DEFAULT_FRIENDLY_NAME]})")
            delete_bookmark(existing[DEFAULT_FRIENDLY_NAME])
        create_bookmark(bookmark_id, args.friendly_name, worker.hostname,
                        worker.password)
        bookmark_created = True
        exported = export_bookmark(bookmark_id)
        smart_sizing = re.search(r"smart sizing:i:(\d)", exported)
        dynamic = re.search(r"dynamic resolution:i:(\d)", exported)
        log(f"temporary bookmark {args.friendly_name!r} ({bookmark_id}) created: "
            f"dynamic_resolution={dynamic.group(1) if dynamic else '?'} "
            f"smart_sizing={smart_sizing.group(1) if smart_sizing else '?'} "
            f"address={worker.hostname}")
        if smart_sizing and smart_sizing.group(1) == "1":
            log("note: Windows App stores smart sizing=1 together with dynamic "
                "resolution=1 (CLI normalisation); this is part of the behaviour "
                "under test")

        log("starting live Windows App unified-log capture (info level)")
        stream.start()
        log(f"capturing into {stream.path}")

        print_section("READY FOR THE WINDOWS APP TEST (isolated, production 3389 untouched)")
        print(f"""
A throwaway worker is listening on {worker.hostname} with the test-pattern
backend and a temporary self-signed certificate.
A temporary Windows App bookmark named "{args.friendly_name}" was created.

Please do exactly this, then come back to this terminal:

  1. Switch to Windows App and click the bookmark "{args.friendly_name}".
  2. If Windows App warns that the server certificate cannot be verified
     (expected: this is a temporary self-signed test certificate), choose
     Continue / Connect.
  3. If asked for credentials, use:
         User name: {USERNAME}
         Password:  {worker.password}
     (temporary password, valid only until this run ends)
  4. Wait until the black-and-white test-pattern desktop appears.
  5. Resize the session window 2-3 times: drag a corner or edge, release the
     mouse, wait about 2 seconds, then resize to a different size and release
     again (for example wide -> narrow -> tall).
  6. Close/disconnect the session window (Cmd+W or the close button), then
     press Enter here.
  7. Back in this terminal, press Enter to stop the capture and print the
     diagnosis.

The capture stops automatically after {int(args.duration)} seconds.
The temporary bookmark and the temporary password are removed afterwards.
""")
        print("=" * 78)
        print("Temporary test password (not repeated in the final summary): "
              f"{worker.password}")
        print("=" * 78, flush=True)

        started = time.monotonic()
        wait_for_enter(args.duration, started)
        stream.stop()
        log("capture stopped, stopping test worker")
        worker.stop()

        # Supplement the live stream with the recent log store (info entries can
        # be dropped quickly, but this can still recover entries right after a
        # resize if the stream had a gap).
        try:
            completed = run([str(LOG_BIN), "show", "--info", "--last", "10m",
                             "--style", "compact",
                             "--predicate", 'process == "Windows App"'], timeout=60)
            (directory / "windows-app-logshow.log").write_text(completed.stdout)
        except (subprocess.TimeoutExpired, OSError):
            pass

        worker_text = worker.text()
        client_text = stream.text()
        logshow_text = ""
        try:
            logshow_text = (directory / "windows-app-logshow.log").read_text(errors="replace")
        except OSError:
            pass

        worker_info = worker_summary(worker_text)
        client_info = client_summary(client_text + "\n" + logshow_text)
        final_verdict, observations = verdict(worker_info, client_info)

        print_section("WORKER DISP AUDIT (isolated test worker)")
        print_lines(worker_info["lines"])
        print_section("WINDOWS APP CLIENT LOG (DISP-relevant lines)")
        print_lines(client_info["lines"])
        for observation in observations:
            print("  " + observation)
        print_section("VERDICT")
        print(final_verdict)
        print_section("ARTIFACTS")
        print(f"  temp directory: {directory}")
        print(f"  worker log:     {worker.log_path}")
        print(f"  client log:     {stream.path}")
        if logshow_text:
            print(f"  log show dump:  {directory / 'windows-app-logshow.log'}")
        if args.transport_dump:
            dump = directory / "transport.dump"
            size = dump.stat().st_size if dump.exists() else 0
            print(f"  transport dump: {dump} ({size} bytes; decode with "
                  f"scripts/decode-transport-dump.py)")
        print("  production worker on 3389 and the user's bookmarks were not touched.")
        return 0
    except KeyboardInterrupt:
        log("interrupted")
        return 2
    finally:
        try:
            stream.stop()
        except Exception:
            pass
        try:
            worker.stop()
        except Exception:
            pass
        try:
            if bookmark_created or True:
                if delete_bookmark(bookmark_id):
                    log(f"temporary bookmark {bookmark_id} deleted")
                else:
                    log(f"WARNING: could not delete temporary bookmark {bookmark_id}; "
                        f"remove {DEFAULT_FRIENDLY_NAME!r} manually in Windows App")
        except Exception as error:  # never hide the diagnosis behind cleanup errors
            log(f"WARNING: bookmark cleanup failed: {error}")
        cleanup_credentials(directory)
        print(f"[disp-diagnose] temporary credentials removed; logs kept in {directory}")
        if args.cleanup:
            shutil.rmtree(directory, ignore_errors=True)
            print("[disp-diagnose] temp directory removed (--cleanup)")
        signal.signal(signal.SIGINT, previous_sigint or signal.SIG_DFL)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Isolated MS-RDPEDISP window-resize diagnostic for Windows App "
                    "(never touches the production worker on 3389).")
    parser.add_argument("--worker-binary", default=None,
                        help="worker binary (default: $RDP_TEST_WORKER_BINARY, else "
                             "/tmp/rdp-worker-disp, else bin/rdp-worker)")
    parser.add_argument("--address", default=None,
                        help="LAN IPv4 to bind (default: autodetect)")
    parser.add_argument("--port", type=int, default=None,
                        help="worker port (default: random free port on the address)")
    parser.add_argument("--friendly-name", default=DEFAULT_FRIENDLY_NAME,
                        help=f"temporary bookmark name (default: {DEFAULT_FRIENDLY_NAME})")
    parser.add_argument("--duration", type=int, default=300,
                        help="maximum seconds to wait for the user test (default: 300)")
    parser.add_argument("--transport-dump", action="store_true",
                        help="enable RDP_TRANSPORT_DUMP for the isolated worker")
    parser.add_argument("--cleanup", action="store_true",
                        help="delete the whole temp directory after the run")
    parser.add_argument("--self-test", action="store_true",
                        help="validate the harness (worker, log stream, bookmark "
                             "create/export/delete) without GUI interaction")
    args = parser.parse_args(argv)

    try:
        worker_binary = find_worker_binary(args.worker_binary)
        address = args.address or detect_lan_address()
        if not is_private_lan_ipv4(address):
            raise HarnessError(
                f"--address {address} is not an RFC1918 private IPv4 address")
        log(f"LAN address: {address}")
        log(f"worker binary: {worker_binary}")
        log(f"Windows App: {WINDOWS_APP}")
        if args.self_test:
            return self_test(worker_binary, address)
        return interactive(args, worker_binary, address)
    except HarnessError as error:
        print(f"[disp-diagnose] ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
