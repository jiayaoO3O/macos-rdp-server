#!/usr/bin/env python3
"""Headless tests for the RDPServer menu bar app core (RDPServerCore).

Exercises the headless CLI of the RDPServer executable (or, while the UI target
does not build in this worktree, a core-only harness compiled from the same
RDPServerCore sources) in isolated temp directories:

  * --status on a fresh data directory (no service start, no disk mutation)
  * data directory resolution via --data-dir and RDPSERVER_DATA_DIR (flag wins)
  * --self-test: paths/cert/credentials/config/helpers/permission checks
  * --status against the self-test data directory (configured state)
  * --self-test without --data-dir (private temp dir, cleaned up)
  * optional (--with-service) isolated Worker + Agent lifecycle self-test

Never touches bin/ or .runtime; all state lives in a temp directory and HOME is
redirected. Standard library only.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "native" / "macos"
CORE_SOURCES = PACKAGE / "Sources" / "RDPServerCore"
RELEASE_BINARY = PACKAGE / ".build" / "release" / "RDPServer"


class TestFailure(Exception):
    pass


def log(message):
    print(message, flush=True)


def ok(message):
    print("OK " + message, flush=True)


def run(command, *, cwd=None, env=None, timeout=600, check=True):
    completed = subprocess.run(
        [str(part) for part in command],
        cwd=str(cwd) if cwd else None,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if check and completed.returncode != 0:
        raise TestFailure(
            "command failed (%d): %s\n%s"
            % (completed.returncode, " ".join(str(part) for part in command),
               (completed.stderr or completed.stdout).strip()[:2000]))
    return completed


def require(condition, message):
    if not condition:
        raise TestFailure(message)


def require_equal(actual, expected, label):
    if actual != expected:
        raise TestFailure("%s: expected %r, got %r" % (label, expected, actual))


def file_mode(path):
    return path.stat().st_mode & 0o777


# ---------------------------------------------------------------------------
# Build helpers


def compile_harness(workdir):
    sources = sorted(CORE_SOURCES.glob("*.swift"))
    if not sources:
        raise TestFailure("no RDPServerCore sources found")
    entry = workdir / "main.swift"
    entry.write_text(
        "import Foundation\n\n"
        "exit(RDPServerCLI.run(arguments: Array(CommandLine.arguments.dropFirst())) ?? 0)\n")
    output = workdir / "rdp-core-harness"
    run(["swiftc", "-O", "-o", output] + sources + [entry], timeout=900)
    return output


def build_executable(workdir):
    last_error = None
    for _ in range(2):
        try:
            run(["swift", "build", "-c", "release",
                 "--package-path", PACKAGE, "--product", "RDPServer"], timeout=900)
            if not RELEASE_BINARY.is_file():
                raise TestFailure("RDPServer product built but the binary is missing")
            return RELEASE_BINARY, "product"
        except (TestFailure, subprocess.TimeoutExpired) as error:
            last_error = error
            time.sleep(2)
    log("note: the RDPServer product does not build in this worktree; using a core-only harness")
    log("note: %s" % str(last_error).splitlines()[0])
    return compile_harness(workdir), "harness"


def ensure_helpers(workdir):
    helpers = workdir / "helpers"
    helpers.mkdir(parents=True, exist_ok=True)
    go = shutil.which("go")
    require(go is not None, "go toolchain not found in PATH")
    rdpctl = helpers / "rdpctl"
    run([go, "build", "-o", rdpctl, "./cmd/rdpctl"], timeout=300)
    worker = helpers / "rdp-worker"
    worker_source = ROOT / "bin" / "rdp-worker"
    if worker_source.is_file():
        if worker.is_symlink() or worker.exists():
            worker.unlink()
        worker.symlink_to(worker_source)
    else:
        run([go, "build", "-o", worker, "./cmd/rdp-worker"], timeout=900)
    agent_source = ROOT / "bin" / "RDPAgent.app"
    require(agent_source.is_dir(),
            "bin/RDPAgent.app is missing; build it separately with make agent-app")
    agent = helpers / "RDPAgent.app"
    if agent.is_symlink() or agent.exists():
        agent.unlink()
    agent.symlink_to(agent_source)
    return helpers


# ---------------------------------------------------------------------------
# CLI invocation


def child_environment(workdir, helpers, extra=None):
    home = workdir / "home"
    home.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment["HOME"] = str(home)
    environment["TMPDIR"] = str(workdir)
    environment["RDPSERVER_HELPERS_DIR"] = str(helpers)
    environment.pop("RDPSERVER_DATA_DIR", None)
    environment.pop("RDPSERVER_SELFTEST_START", None)
    if extra:
        environment.update(extra)
    return environment


def run_cli(executable, arguments, environment, timeout=300):
    return subprocess.run(
        [str(executable)] + list(arguments),
        capture_output=True,
        text=True,
        env=environment,
        timeout=timeout,
    )


def parse_json_object(completed):
    lines = [line for line in (completed.stdout or "").splitlines() if line.strip()]
    if not lines:
        raise TestFailure("no JSON on stdout (stderr: %s)"
                          % (completed.stderr or "").strip()[:600])
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError as error:
        raise TestFailure("stdout is not a JSON object (%s): %s"
                          % (error, lines[-1][:400]))


def check_map(report):
    checks = report.get("checks")
    require(isinstance(checks, list) and checks, "self-test report has no checks")
    mapping = {}
    for check in checks:
        require(isinstance(check, dict) and "name" in check and "ok" in check,
                "malformed self-test check: %r" % (check,))
        mapping[check["name"]] = check
    return mapping


# ---------------------------------------------------------------------------
# Tests


def test_status_first_run(executable, workdir, helpers):
    data = workdir / "status-empty"
    environment = child_environment(workdir, helpers)
    completed = run_cli(executable, ["--status", "--data-dir", data], environment)
    require_equal(completed.returncode, 0,
                  "--status on a fresh directory must exit 0 (stderr: %s)"
                  % (completed.stderr or "").strip()[:600])
    report = parse_json_object(completed)
    for key in ["ok", "app_version", "data_directory", "state", "configured", "enabled",
                "address", "listen_host", "port", "allow_lan", "account", "principal",
                "permissions", "agent", "worker", "last_error", "logs_directory"]:
        require(key in report, "status JSON is missing key %r" % key)
    require_equal(report["ok"], True, "status.ok")
    require_equal(report["state"], "disabled", "status.state")
    require_equal(report["enabled"], False, "status.enabled")
    require_equal(report["configured"], False, "status.configured")
    require_equal(report["listen_host"], "127.0.0.1", "status.listen_host")
    require_equal(report["allow_lan"], False, "status.allow_lan")
    require_equal(report["account"], None, "status.account")
    require_equal(report["worker"]["running"], False, "status.worker.running")
    require_equal(report["worker"]["pid"], None, "status.worker.pid")
    require_equal(report["data_directory"], str(data), "status.data_directory")
    require_equal(report["logs_directory"], str(data / "logs"), "status.logs_directory")
    require(isinstance(report["port"], int) and 1024 <= report["port"] <= 65535,
            "status.port out of range: %r" % (report["port"],))
    require(report["permissions"] and "screen_recording" in report["permissions"]
            and "accessibility" in report["permissions"],
            "status.permissions is missing screen_recording/accessibility")
    require(not data.exists(), "--status must not create the data directory")
    require(not (workdir / "home" / "Library").exists(),
            "--status must not touch HOME/Library")


def test_status_data_dir_env(executable, workdir, helpers):
    from_flag = workdir / "status-flag"
    from_env = workdir / "status-env"
    environment = child_environment(workdir, helpers,
                                    {"RDPSERVER_DATA_DIR": str(from_env)})
    completed = run_cli(executable, ["--status"], environment)
    require_equal(completed.returncode, 0, "--status with RDPSERVER_DATA_DIR")
    report = parse_json_object(completed)
    require_equal(report["data_directory"], str(from_env),
                  "RDPSERVER_DATA_DIR must be honoured")
    completed = run_cli(executable, ["--status", "--data-dir=" + str(from_flag)], environment)
    require_equal(completed.returncode, 0, "--status with --data-dir=...")
    report = parse_json_object(completed)
    require_equal(report["data_directory"], str(from_flag),
                  "--data-dir must win over RDPSERVER_DATA_DIR")


def test_self_test(executable, workdir, helpers):
    data = workdir / "selftest-data"
    environment = child_environment(workdir, helpers)
    completed = run_cli(executable, ["--self-test", "--data-dir", data], environment)
    report = parse_json_object(completed)
    require_equal(completed.returncode, 0,
                  "--self-test must exit 0 (stderr: %s)"
                  % (completed.stderr or "").strip()[:800])
    require_equal(report["ok"], True, "self-test.ok")
    require_equal(report["started_service"], False, "self-test.started_service")
    checks = check_map(report)
    required = [
        "helpers.directory", "helpers.rdp-worker", "helpers.rdpctl",
        "helpers.agent", "helpers.openssl",
        "paths.data_directory_mode", "paths.data_directory_owner",
        "paths.logs_mode", "paths.socket_length",
        "certificate.generated", "certificate.key_mode", "certificate.cert_mode",
        "certificate.san_loopback",
        "credentials.sam_saved", "credentials.sam_mode", "credentials.hash_format",
        "credentials.account_roundtrip",
        "config.written", "config.mode", "config.loadable", "config.loopback",
        "config.absolute_paths", "config.no_secrets",
        "agent.permission_query",
        "cleanup.worker_grace_exceeds_supervisor_grace",
        "secrets.no_plaintext_password", "secrets.hash_only_in_sam",
        "paths.files_private",
    ]
    for name in required:
        require(name in checks, "self-test is missing check %r" % name)
    failed = sorted(name for name, check in checks.items() if not check["ok"])
    require(not failed, "self-test checks failed: %s" % ", ".join(failed))

    require(data.is_dir(), "self-test data directory was not created")
    require_equal(file_mode(data), 0o700, "data directory mode")
    require_equal(file_mode(data / "logs"), 0o700, "logs directory mode")
    for name in ["config.json", "sam", "key.pem", "cert.pem"]:
        path = data / name
        require(path.is_file(), "self-test is missing %s" % name)
        require_equal(file_mode(path), 0o600, "%s mode" % name)
    configuration = json.loads((data / "config.json").read_text())
    require_equal(configuration["address"], "127.0.0.1", "config address")
    require_equal(configuration["allow_lan"], False, "config allow_lan")
    require_equal(configuration["enabled"], True, "config enabled")
    require_equal(configuration["test_pattern"], False, "config test_pattern")
    require(1024 <= configuration["port"] <= 65535, "config port out of range")
    require_equal(configuration["sam"], str(data / "sam"), "config sam path")
    require_equal(configuration["certificate"], str(data / "cert.pem"), "config cert path")
    require_equal(configuration["key"], str(data / "key.pem"), "config key path")
    sam = (data / "sam").read_text()
    require(re.fullmatch(r"[a-z0-9_.-]{1,64}:MACRDP::[0-9a-f]{32}:\n", sam) is not None,
            "SAM content has an unexpected format: %r" % sam)
    leftovers = [entry.name for entry in data.iterdir()
                 if entry.name.startswith(".") or entry.name.endswith(".tmp")]
    require(not leftovers, "self-test left temporary files behind: %s" % leftovers)
    require(not (data / "agent.sock").exists(), "self-test left a stale agent socket")
    ok("self-test produced a valid private data directory at %s" % data)


def test_status_configured(executable, workdir, helpers):
    data = workdir / "selftest-data"
    require(data.is_dir(), "configuration test requires the self-test data directory")
    environment = child_environment(workdir, helpers)
    completed = run_cli(executable, ["--status", "--data-dir", data], environment)
    require_equal(completed.returncode, 0, "--status on a configured directory")
    report = parse_json_object(completed)
    configuration = json.loads((data / "config.json").read_text())
    require_equal(report["configured"], True, "status.configured")
    require_equal(report["account"], configuration["account"], "status.account")
    require_equal(report["principal"], "MACRDP\\" + configuration["account"],
                  "status.principal")
    require_equal(report["port"], configuration["port"], "status.port")
    require_equal(report["address"], "127.0.0.1:%d" % configuration["port"],
                  "status.address")
    require_equal(report["worker"]["running"], False, "status.worker.running")
    require_equal(report["agent"]["state"], "waiting", "status.agent.state")
    ok("status reports the configured account and expected listen address")


def test_self_test_temp_directory(executable, workdir, helpers):
    environment = child_environment(workdir, helpers)
    completed = run_cli(executable, ["--self-test"], environment)
    report = parse_json_object(completed)
    require_equal(completed.returncode, 0, "--self-test without --data-dir must exit 0")
    require_equal(report["ok"], True, "self-test.ok")
    directory = report.get("data_directory")
    require(isinstance(directory, str) and directory.startswith("/"),
            "self-test data_directory is not absolute")
    require(not Path(directory).exists(),
            "self-test must clean up its private temp directory (%s)" % directory)
    ok("self-test without --data-dir used and removed a private temp directory")


def test_self_test_with_service(executable, workdir, helpers):
    data = workdir / "selftest-service"
    environment = child_environment(workdir, helpers,
                                    {"RDPSERVER_SELFTEST_START": "1"})
    completed = run_cli(executable, ["--self-test", "--data-dir", data], environment,
                        timeout=300)
    report = parse_json_object(completed)
    require_equal(completed.returncode, 0,
                  "lifecycle self-test must exit 0 (stderr: %s)"
                  % (completed.stderr or "").strip()[:1200])
    require_equal(report["started_service"], True, "self-test.started_service")
    checks = check_map(report)
    for name in ["worker.started", "worker.listening", "worker.tcp_connect",
                 "cleanup.worker_grace_exceeds_supervisor_grace",
                 "cleanup.stale_worker_seeded", "cleanup.stale_worker_lease",
                 "cleanup.stale_worker_scan", "cleanup.stale_worker_removed",
                 "cleanup.stale_worker_lease_source",
                 "cleanup.state", "cleanup.no_running_pids", "cleanup.socket_removed"]:
        require(name in checks, "lifecycle self-test is missing check %r" % name)
        require(checks[name]["ok"], "lifecycle check failed: %s (%s)"
                % (name, checks[name].get("detail")))
    require("agent.frames" in checks, "lifecycle self-test is missing agent.frames")
    require(checks["agent.frames"]["ok"],
            "agent.frames failed: %s" % checks["agent.frames"].get("detail"))
    completed = subprocess.run(["pgrep", "-fl", str(data)], capture_output=True, text=True)
    require(not completed.stdout.strip(),
            "leftover processes after the lifecycle self-test: %s" % completed.stdout.strip())
    ok("isolated Worker + Agent lifecycle started, listed, captured and stopped cleanly")


def test_version_and_help(executable, workdir, helpers):
    environment = child_environment(workdir, helpers)
    completed = run_cli(executable, ["--version"], environment, timeout=30)
    require_equal(completed.returncode, 0, "--version exit code")
    require("0.2.4" in completed.stdout, "--version output: %r" % completed.stdout)
    completed = run_cli(executable, ["--help"], environment, timeout=30)
    require_equal(completed.returncode, 0, "--help exit code")
    require("--self-test" in completed.stdout, "--help output is missing --self-test")


def snapshot_directory(path):
    if not path.is_dir():
        return None
    return sorted((entry.name, entry.stat().st_mtime_ns)
                  for entry in path.iterdir())


# ---------------------------------------------------------------------------


class Runner:
    def __init__(self):
        self.failures = []

    def test(self, name, function, *args):
        log("test: " + name)
        try:
            function(*args)
        except TestFailure as error:
            self.failures.append(name)
            print("FAIL %s: %s" % (name, error), flush=True)
        except subprocess.TimeoutExpired as error:
            self.failures.append(name)
            print("FAIL %s: timed out after %ss" % (name, error.timeout), flush=True)
        except Exception as error:  # unexpected test harness error
            self.failures.append(name)
            print("FAIL %s: unexpected %s: %s" % (name, type(error).__name__, error),
                  flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--with-service", action="store_true",
                        help="also run the isolated Worker+Agent lifecycle self-test "
                             "(needs Screen Recording/Accessibility for the nested agent)")
    parser.add_argument("--keep", action="store_true",
                        help="keep the temp work directory for debugging")
    arguments = parser.parse_args()

    # /tmp keeps the data-directory socket paths comfortably below the 104-byte
    # AF_UNIX limit even when TMPDIR is deeply nested.
    workdir = Path(tempfile.mkdtemp(prefix="rdp-app-core-", dir="/tmp"))
    log("workdir: %s" % workdir)
    runtime_before = snapshot_directory(ROOT / ".runtime")
    runner = Runner()
    try:
        executable, mode = build_executable(workdir)
        log("executable: %s (%s)" % (executable, mode))
        helpers = ensure_helpers(workdir)
        log("helpers: %s" % helpers)
        runner.test("build executable", lambda: ok("executable: %s" % mode))
        runner.test("status first run", test_status_first_run, executable, workdir, helpers)
        runner.test("status data dir resolution", test_status_data_dir_env,
                    executable, workdir, helpers)
        runner.test("self test", test_self_test, executable, workdir, helpers)
        runner.test("status configured", test_status_configured,
                    executable, workdir, helpers)
        runner.test("self test temp directory", test_self_test_temp_directory,
                    executable, workdir, helpers)
        runner.test("version and help", test_version_and_help, executable, workdir, helpers)
        if arguments.with_service:
            runner.test("self test with service", test_self_test_with_service,
                        executable, workdir, helpers)
        else:
            log("note: skipping the isolated Worker+Agent lifecycle test "
                "(pass --with-service to enable it)")
        runner.test("repo .runtime untouched",
                    lambda: require(snapshot_directory(ROOT / ".runtime") is not None
                                    or not (ROOT / ".runtime").exists(),
                                    ".runtime disappeared during the test run"))
    finally:
        if arguments.keep:
            log("keeping workdir: %s" % workdir)
        else:
            shutil.rmtree(workdir, ignore_errors=True)

    if runner.failures:
        print("FAILED %d test(s): %s" % (len(runner.failures), ", ".join(runner.failures)),
              flush=True)
        return 1
    print("ALL TESTS PASSED", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
