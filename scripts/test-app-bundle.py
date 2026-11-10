#!/usr/bin/env python3
"""Verify the packaged RDPServer.app inside dist/RDPServer-0.2.3.dmg (stdlib only).

Checks the drag-install artifact as a user would get it:

  * the DMG mounts, contains RDPServer.app + an Applications -> /Applications symlink
  * bundle layout / Info.plist are sane (menu bar app identity)
  * Contents/Resources/Licenses/ ships LICENSE, NOTICE and
    THIRD-PARTY-NOTICES.md byte-for-byte (size floor + sha256 against the
    repository root files, expected markers present)
  * codesign --verify --deep --strict passes (ad-hoc signature)
  * every non-system dependency of every Mach-O resolves via @rpath to
    Contents/Frameworks (no /opt/homebrew or repo .deps absolute paths)
  * the bundled rdp-worker actually loads all dylibs (fails on missing config,
    not on dyld errors) and rdpctl starts
  * the nested RDPAgent.app reports permissions (status)
  * RDPServer --status / --self-test produce JSON in an isolated temp data dir
  * no writes to the live ~/Library/Application Support/RDPServer or repo .runtime

Everything runs from the mounted (read-only) DMG with HOME/TMPDIR redirected to a
temp dir. The script never starts the RDP service and never touches .runtime/.

Exits non-zero if any check fails; missing app CLI support is reported as FAIL
(until the app lands) or SKIP for --self-test when --status is unavailable.
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
DMG_PATH = DIST / "RDPServer-0.2.3.dmg"
PACKAGER = ROOT / "scripts/package-app-dmg.py"

APP_NAME = "RDPServer.app"
APP_EXECUTABLE = "RDPServer"
BUNDLE_ID = "com.rdp-server.server"
EXPECTED_VERSION = "0.2.3"
NESTED_AGENT_NAME = "RDPAgent.app"
NESTED_AGENT_EXECUTABLE = "rdp-agent"
AGENT_BUNDLE_ID = "com.rdp-server.agent"

HELPERS = ("rdp-worker", "rdpctl")
FRAMEWORKS_RPATH = "@executable_path/../Frameworks"
LICENSES_DIR = "Licenses"
LICENSE_FILES = ("LICENSE", "NOTICE", "THIRD-PARTY-NOTICES.md")
# Markers that prove the full file (not a truncated copy) was shipped. Expected
# sizes and sha256 are computed from the current repository root files, never
# hard-coded, so a rebuilt bundle is always compared against this tree.
LICENSE_MARKERS = {
    "LICENSE": ("Apache License", "Version 2.0", "END OF TERMS AND CONDITIONS"),
    "NOTICE": ("FreeRDP", "OpenSSL", "json-c", "Go runtime"),
    "THIRD-PARTY-NOTICES.md": ("MIT", "BSD-3-Clause", "Apache-2.0"),
}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Apple/")
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}

REAL_DATA_DIR = Path.home() / "Library/Application Support/RDPServer"
REAL_PREFERENCES = Path.home() / "Library/Preferences/com.rdp-server.server.plist"
LIVE_RUNTIME_DIR = ROOT / ".runtime"


class CheckFailure(Exception):
    pass


class Checker:
    def __init__(self):
        self.failures = []
        self.skips = []
        self.warnings = []
        self.passed = 0

    def ok(self, name, detail=""):
        self.passed += 1
        print(f"OK   {name}" + (f"  ({detail})" if detail else ""))

    def fail(self, name, detail=""):
        self.failures.append(name)
        print(f"FAIL {name}" + (f"  ({detail})" if detail else ""))

    def skip(self, name, detail=""):
        self.skips.append(name)
        print(f"SKIP {name}" + (f"  ({detail})" if detail else ""))

    def warn(self, name, detail=""):
        self.warnings.append(name)
        print(f"WARN {name}" + (f"  ({detail})" if detail else ""))

    def run(self, name, function):
        """Run one check; return its result (or None on failure)."""
        try:
            detail = function()
        except CheckFailure as error:
            self.fail(name, str(error))
            return None
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            self.fail(name, f"unexpected error: {error}")
            return None
        self.ok(name, "" if detail is None else str(detail))
        return detail if detail is not None else True

    def total(self):
        """Number of checks actually executed (passed + failed + skipped)."""
        return self.passed + len(self.failures) + len(self.skips)


def print_summary(checker):
    """Print the dynamic check summary (never hardcode a check count)."""
    print()
    print(f"{checker.passed} passed, {len(checker.failures)} failed, "
          f"{len(checker.skips)} skipped, {len(checker.warnings)} warning(s); "
          f"{checker.total()} check(s)")
    if checker.warnings:
        print("warnings: " + ", ".join(checker.warnings))
    if checker.failures:
        print("failures: " + ", ".join(checker.failures))


def run(command, *, cwd=None, env=None, timeout=60, echo=False, stdin_text=None):
    if echo:
        print(f"  $ {' '.join(str(part) for part in command)}")
    return subprocess.run(
        [str(part) for part in command],
        cwd=str(cwd) if cwd else None,
        env=env,
        input=stdin_text,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


def is_system_path(path):
    return path.startswith(SYSTEM_PREFIXES)


def otool_deps(path):
    completed = run(["otool", "-L", str(path)])
    require(completed.returncode == 0, f"otool -L failed for {path}: {completed.stderr.strip()}")
    dependencies = []
    for line in completed.stdout.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        dependency = line.split(" (compatibility version", 1)[0].strip()
        if dependency:
            dependencies.append(dependency)
    return dependencies


def otool_dylib_id(path):
    completed = run(["otool", "-D", str(path)])
    entries = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    return entries[1] if len(entries) > 1 else None


def otool_rpaths(path):
    completed = run(["otool", "-l", str(path)])
    lines = completed.stdout.splitlines()
    rpaths = []
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for following in lines[index + 1:index + 4]:
            stripped = following.strip()
            if stripped.startswith("path "):
                rpaths.append(stripped[len("path "):].rsplit(" (offset", 1)[0].strip())
                break
    return rpaths


def is_macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    try:
        with open(path, "rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def machos_in(app_path):
    return [path for path in sorted(app_path.rglob("*")) if is_macho(path)]


def isolated_environment(home, temporary):
    home.mkdir(parents=True, exist_ok=True)
    temporary.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment["HOME"] = str(home)
    environment["TMPDIR"] = str(temporary) + os.sep
    environment["RDP_AGENT_NO_PERMISSION_REQUEST"] = "1"
    # Never let dev/test switches inherited from the caller change app behavior.
    for variable in (
        "RDPSERVER_DATA_DIR", "RDPSERVER_HELPERS_DIR", "RDPSERVER_SELFTEST_START",
        "RDPSERVER_OPEN_POPOVER", "RDPSERVER_UI_MOCK", "RDPSERVER_UI_SNAPSHOT",
        "RDPSERVER_UI_SMOKE", "RDP_AGENT_CLIPBOARD_STAGING",
    ):
        environment.pop(variable, None)
    return environment


def snapshot(paths):
    state = {}
    for path in paths:
        try:
            stat = path.stat()
        except FileNotFoundError:
            state[str(path)] = (False, None, ())
            continue
        entries = ()
        if path.is_dir():
            try:
                entries = tuple(sorted(child.name for child in path.iterdir()))
            except OSError:
                entries = ()
        state[str(path)] = (True, stat.st_mtime_ns, entries)
    return state


def parse_single_json(text):
    stripped = text.strip()
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        value = None
    if isinstance(value, dict):
        return value
    objects = []
    for line in stripped.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            objects.append(candidate)
    require(len(objects) == 1, f"expected exactly one JSON object on stdout, got {len(objects)}: {stripped[:400]!r}")
    return objects[0]


NT_HASH_PATTERN = re.compile(r"\b[0-9a-fA-F]{32}\b")


def reject_secret_keys(report):
    """No credential material may be printed: no password field and no 32-hex
    value (an NT hash) anywhere in the report."""

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                require("password" not in str(key).lower(),
                        f"report leaks a password-looking key {key!r}")
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
        elif isinstance(value, str):
            require(NT_HASH_PATTERN.search(value) is None,
                    f"report contains a 32-hex value that looks like an NT hash: {value[:32]!r}")

    walk(report)


STALE_MOUNT_PREFIXES = ("/tmp/rdp-app-bundle-", "/private/tmp/rdp-app-bundle-")


def mounted_images():
    """Return {image path: mount point} from hdiutil info -plist."""
    completed = run(["hdiutil", "info", "-plist"], timeout=60)
    if completed.returncode != 0:
        return {}
    try:
        info = plistlib.loads(completed.stdout.encode())
    except plistlib.InvalidFileException:
        return {}
    images = {}
    for image in info.get("images", []):
        image_path = image.get("image-path")
        if not image_path:
            continue
        for entity in image.get("system-entities", []):
            mount_point = entity.get("mount-point")
            if mount_point:
                images[str(Path(image_path).resolve())] = Path(mount_point)
                break
    return images


def detach_mount(mountpoint):
    detach = run(["hdiutil", "detach", str(mountpoint)], timeout=120)
    if detach.returncode != 0:
        run(["hdiutil", "detach", "-force", str(mountpoint)], timeout=120)


class DmgMount:
    """Mount the DMG read-only.

    If the image is already mounted (a previous run, or a human inspecting the
    DMG) the existing mount is reused and left alone; stale mounts created by an
    interrupted verifier run are detached first.
    """

    def __init__(self, dmg_path):
        self.dmg_path = dmg_path
        # /tmp keeps the worker's AF_UNIX socket path below the 104-byte limit.
        self.temporary = Path(tempfile.mkdtemp(prefix="rdp-app-bundle-", dir="/tmp"))
        self.mountpoint = self.temporary / "mnt"
        self.mountpoint.mkdir()
        self.attach_output = ""
        self.owned = False

    def __enter__(self):
        existing = mounted_images().get(str(self.dmg_path.resolve()))
        if existing is not None:
            if str(existing).startswith(STALE_MOUNT_PREFIXES):
                print(f"detaching stale mount {existing}")
                detach_mount(existing)
            else:
                print(f"reusing existing mount {existing} (leaving it mounted)")
                self.mountpoint = existing
                self.attach_output = "reused existing mount"
                return self
        completed = run([
            "hdiutil", "attach", "-nobrowse", "-readonly",
            "-mountpoint", str(self.mountpoint), str(self.dmg_path),
        ], timeout=120)
        self.attach_output = completed.stdout + completed.stderr
        require(completed.returncode == 0, f"hdiutil attach failed: {self.attach_output.strip()}")
        require(self.mountpoint.is_dir(), "DMG mountpoint missing after attach")
        self.owned = True
        return self

    def __exit__(self, *exception):
        if self.owned and self.mountpoint.is_dir():
            detach_mount(self.mountpoint)
        shutil.rmtree(self.temporary, ignore_errors=True)
        return False


def ensure_dmg(dmg_path, no_build):
    if dmg_path.is_file():
        print(f"using existing {dmg_path}")
        return
    require(not no_build, f"{dmg_path} does not exist (and --no-build was given)")
    print(f"{dmg_path} missing; running scripts/package-app-dmg.py --swift-build")
    completed = run([sys.executable, str(PACKAGER), "--swift-build"], timeout=1200)
    require(completed.returncode == 0,
            f"packaging failed: {(completed.stdout + completed.stderr)[-2000:]}")
    require(dmg_path.is_file(), f"{dmg_path} was not produced")


def check_volume_label(mountpoint):
    completed = run(["diskutil", "info", "-plist", str(mountpoint)])
    require(completed.returncode == 0, f"diskutil info failed: {completed.stderr.strip()}")
    try:
        info = plistlib.loads(completed.stdout.encode())
    except plistlib.InvalidFileException as error:
        raise CheckFailure(f"cannot parse diskutil info plist: {error}") from error
    volume_name = info.get("VolumeName")
    require(volume_name == "RDP Server", f"DMG volume label is {volume_name!r}, expected 'RDP Server'")
    return f"volume 'RDP Server' mounted at {mountpoint.name}"


def check_dmg_contents(mountpoint):
    app = mountpoint / APP_NAME
    require(app.is_dir(), f"{APP_NAME} missing from the DMG")
    require(not app.is_symlink(), f"{APP_NAME} must be a real directory")
    applications = mountpoint / "Applications"
    require(applications.is_symlink(), "DMG is missing the Applications symlink")
    target = os.readlink(applications)
    require(target == "/Applications", f"Applications symlink points at {target!r}")
    return f"{APP_NAME} + Applications -> {target}"


def load_plist(path):
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise CheckFailure(f"cannot read {path}: {error}") from error


def check_layout(app):
    executable = app / "Contents/MacOS" / APP_EXECUTABLE
    require(executable.is_file(), f"missing {executable.relative_to(app)}")
    require(os.access(executable, os.X_OK), f"{APP_EXECUTABLE} is not executable")
    for name in HELPERS:
        helper = app / "Contents/Helpers" / name
        require(helper.is_file(), f"missing Contents/Helpers/{name}")
        require(os.access(helper, os.X_OK), f"Contents/Helpers/{name} is not executable")
    agent_executable = app / "Contents/Helpers" / NESTED_AGENT_NAME / "Contents/MacOS" / NESTED_AGENT_EXECUTABLE
    require(agent_executable.is_file(), "missing nested RDPAgent.app executable")
    require(os.access(agent_executable, os.X_OK), "nested agent executable is not executable")
    frameworks = sorted((app / "Contents/Frameworks").glob("*.dylib"))
    require(frameworks, "Contents/Frameworks has no dylibs")
    return f"{len(frameworks)} dylibs, helpers + nested agent present"


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_freerdp_version():
    """Pinned FreeRDP version, read from the build script (never hard-coded)."""
    script = ROOT / "scripts" / "build-freerdp.sh"
    try:
        text = script.read_text()
    except OSError as error:
        raise CheckFailure(f"cannot read {script}: {error}") from error
    match = re.search(r"^version=(\S+)$", text, re.MULTILINE)
    if not match:
        raise CheckFailure(f"cannot find the pinned FreeRDP version in {script}")
    return match.group(1)


def check_licenses(app):
    directory = app / "Contents/Resources" / LICENSES_DIR
    require(directory.is_dir(), f"missing Contents/Resources/{LICENSES_DIR}")
    freerdp_version = expected_freerdp_version()
    markers_by_name = {
        "LICENSE": LICENSE_MARKERS["LICENSE"],
        "NOTICE": LICENSE_MARKERS["NOTICE"],
        # Component versions come from the pinned build, not from a hard-coded
        # copy of the notice text itself.
        "THIRD-PARTY-NOTICES.md": LICENSE_MARKERS["THIRD-PARTY-NOTICES.md"] + (freerdp_version,),
    }
    details = []
    for name in LICENSE_FILES:
        source = ROOT / name
        require(source.is_file(), f"repo root {name} is missing; cannot verify its shipped copy")
        expected_bytes = source.read_bytes()
        expected_size = len(expected_bytes)
        expected_sha = hashlib.sha256(expected_bytes).hexdigest()
        path = directory / name
        relative = path.relative_to(app)
        require(path.is_file(),
                f"missing {relative} (repo {name}: {expected_size} bytes, sha256 {expected_sha})")
        actual_size = path.stat().st_size
        require(actual_size >= expected_size,
                f"{relative} is {actual_size} bytes, expected at least {expected_size} bytes "
                f"(repo {name}, sha256 {expected_sha})")
        text = path.read_text(errors="replace")
        for marker in markers_by_name[name]:
            require(marker in text,
                    f"{relative} does not contain {marker!r} (expected marker from repo {name})")
        actual_sha = sha256_file(path)
        require(actual_sha == expected_sha,
                f"{relative} sha256 {actual_sha} != repo {name} sha256 {expected_sha} "
                f"({actual_size} vs {expected_size} bytes)")
        details.append(f"{name} {actual_size}B sha256={actual_sha[:12]}\u2026")
    return ", ".join(details)


def check_info_plist(app):
    info = load_plist(app / "Contents/Info.plist")
    require(info.get("CFBundleIdentifier") == BUNDLE_ID,
            f"CFBundleIdentifier is {info.get('CFBundleIdentifier')!r}")
    require(info.get("CFBundleExecutable") == APP_EXECUTABLE,
            f"CFBundleExecutable is {info.get('CFBundleExecutable')!r}")
    require(info.get("CFBundleName") == "RDP Server", f"CFBundleName is {info.get('CFBundleName')!r}")
    require(info.get("CFBundleShortVersionString") == EXPECTED_VERSION,
            f"CFBundleShortVersionString is {info.get('CFBundleShortVersionString')!r}")
    require(str(info.get("CFBundleVersion")) == "1", f"CFBundleVersion is {info.get('CFBundleVersion')!r}")
    require(info.get("LSMinimumSystemVersion") == "14.0",
            f"LSMinimumSystemVersion is {info.get('LSMinimumSystemVersion')!r}")
    require(info.get("LSUIElement") is True, "LSUIElement must be true for a menu bar app")
    require(info.get("NSHighResolutionCapable") is True, "NSHighResolutionCapable must be true")
    return f"{BUNDLE_ID} {EXPECTED_VERSION} (build {info.get('CFBundleVersion')}), LSUIElement"


def check_nested_agent_plist(app):
    info = load_plist(app / "Contents/Helpers" / NESTED_AGENT_NAME / "Contents/Info.plist")
    require(info.get("CFBundleIdentifier") == AGENT_BUNDLE_ID,
            f"nested agent id is {info.get('CFBundleIdentifier')!r}")
    require(info.get("CFBundleExecutable") == NESTED_AGENT_EXECUTABLE,
            f"nested agent executable is {info.get('CFBundleExecutable')!r}")
    require(info.get("LSUIElement") is True, "nested agent LSUIElement must be true")
    require(info.get("CFBundleShortVersionString"), "nested agent has no version")
    return f"{AGENT_BUNDLE_ID} {info.get('CFBundleShortVersionString')}, LSUIElement"


def codesign_details(path):
    completed = run(["codesign", "-dvv", str(path)])
    return completed.stdout + completed.stderr


def parse_codesign_identifier(details):
    for line in details.splitlines():
        if line.startswith("Identifier="):
            return line.split("=", 1)[1].strip()
    return None


def check_codesign(app):
    completed = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], timeout=120)
    require(completed.returncode == 0,
            f"codesign --verify --deep --strict failed: {(completed.stdout + completed.stderr).strip()}")
    details = codesign_details(app)
    require("Signature=adhoc" in details, "outer app is not ad-hoc signed (Signature=adhoc missing)")
    outer_identifier = parse_codesign_identifier(details)
    require(outer_identifier == BUNDLE_ID, f"outer identifier is {outer_identifier!r}")

    nested = app / "Contents/Helpers" / NESTED_AGENT_NAME
    nested_verify = run(["codesign", "--verify", "--deep", "--strict", str(nested)])
    require(nested_verify.returncode == 0, "nested RDPAgent.app signature is invalid")
    nested_identifier = parse_codesign_identifier(codesign_details(nested))
    require(nested_identifier == AGENT_BUNDLE_ID,
            f"nested identifier is {nested_identifier!r}; TCC identity must stay {AGENT_BUNDLE_ID}")
    nested_details = codesign_details(nested)
    require("Signature=adhoc" in nested_details, "nested agent is not ad-hoc signed")
    return f"adhoc, deep+strict verify passed; identifiers {outer_identifier} / {nested_identifier}"


def check_relocation(app):
    frameworks = app / "Contents/Frameworks"
    framework_names = {path.name for path in frameworks.glob("*.dylib")}
    require(framework_names, "no bundled dylibs to check")
    machos = machos_in(app)
    require(machos, "no Mach-O files found in the bundle")
    problems = []
    for macho in machos:
        relative = macho.relative_to(app)
        for dependency in otool_deps(macho):
            if is_system_path(dependency):
                continue
            if not dependency.startswith("@rpath/"):
                problems.append(f"{relative}: absolute dependency {dependency}")
                continue
            name = dependency[len("@rpath/"):]
            if "/" in name:
                problems.append(f"{relative}: unexpected @rpath component {dependency}")
            elif name not in framework_names:
                problems.append(f"{relative}: {dependency} missing from Contents/Frameworks")
        rpaths = otool_rpaths(macho)
        for rpath in rpaths:
            if ("/.deps/" in rpath or rpath.startswith(str(ROOT) + "/")
                    or rpath.startswith("/opt/homebrew") or rpath.startswith("/Library/Developer/")):
                problems.append(f"{relative}: absolute dev rpath {rpath}")
        if macho.suffix == ".dylib":
            identifier = otool_dylib_id(macho)
            if identifier and not identifier.startswith("@rpath/"):
                problems.append(f"{relative}: absolute install id {identifier}")
        has_external_dependency = any(not is_system_path(dep) for dep in otool_deps(macho))
        if has_external_dependency and macho.suffix != ".dylib":
            if FRAMEWORKS_RPATH not in rpaths:
                problems.append(f"{relative}: missing rpath {FRAMEWORKS_RPATH}")
    require(not problems, "; ".join(problems))
    return f"{len(machos)} Mach-O files, all non-system deps @rpath -> Contents/Frameworks"


def check_worker_dyld(app, working_directory, environment):
    worker = app / "Contents/Helpers/rdp-worker"
    completed = run([worker, "-config", str(working_directory / "missing-config.json")],
                    cwd=working_directory, env=environment, timeout=60)
    output = (completed.stdout + completed.stderr).lower()
    require(completed.returncode != 0, "rdp-worker unexpectedly accepted a missing config")
    for symptom in ("library not loaded", "image not found", "dyld"):
        require(symptom not in output, f"rdp-worker hit a dyld error ({symptom}): {output[-400:]}")
    require("no such file" in output or "lstat" in output or "config" in output,
            f"rdp-worker did not report the config error: {output[-400:]}")
    return f"exit {completed.returncode}, config error (all dylibs loaded)"


def check_rdpctl_dyld(app, working_directory, environment):
    completed = run([app / "Contents/Helpers/rdpctl"], cwd=working_directory, env=environment, timeout=60)
    output = (completed.stdout + completed.stderr).lower()
    for symptom in ("library not loaded", "image not found", "dyld"):
        require(symptom not in output, f"rdpctl hit a dyld error ({symptom}): {output[-400:]}")
    require(completed.returncode == 2, f"rdpctl without arguments exited {completed.returncode}, expected 2")
    return "starts and prints usage (all dylibs loaded)"


def write_private_file(path, content):
    path.write_text(content, encoding="utf-8")
    os.chmod(path, 0o600)


def check_worker_startup(app, workspace, environment):
    """Start the bundled worker with a throwaway config on a random loopback port.

    Proves the whole dylib graph loads and the cgo FreeRDP server initializes
    from the bundle, without touching the live .runtime or port 3389.
    """
    import random
    import time

    worker = app / "Contents/Helpers/rdp-worker"
    rdpctl = app / "Contents/Helpers/rdpctl"
    data = workspace / "worker-startup"
    data.mkdir(parents=True, exist_ok=True)
    os.chmod(data, 0o700)

    account = "packagingcheck"
    password = "temp-" + os.urandom(8).hex()
    hashed = run([rdpctl, "hash-stdin"], cwd=data, env=environment, timeout=30,
                 stdin_text=password + "\n")
    require(hashed.returncode == 0, f"bundled rdpctl hash-stdin failed: {hashed.stderr.strip()}")
    write_private_file(data / "sam", f"{account}:MACRDP::{hashed.stdout.strip()}:\n")
    write_private_file(data / "key.pem", "packaging placeholder, never used for a connection\n")
    write_private_file(data / "cert.pem", "packaging placeholder, never used for a connection\n")

    socket_path = data / "a.sock"
    output = ""
    port = 0
    listening = False
    for attempt in range(3):
        port = random.randint(20000, 60000)
        configuration = {
            "address": "127.0.0.1",
            "port": port,
            "account": account,
            "enabled": True,
            "test_pattern": True,
            "clipboard": False,
            "certificate": str(data / "cert.pem"),
            "key": str(data / "key.pem"),
            "sam": str(data / "sam"),
        }
        write_private_file(data / "config.json", json.dumps(configuration, indent=2) + "\n")
        log_path = data / f"worker-{attempt}.log"
        with open(log_path, "w", encoding="utf-8") as log:
            process = subprocess.Popen(
                [str(worker), "-config", str(data / "config.json"), "-agent-socket", str(socket_path)],
                cwd=str(data), env=environment, stdout=log, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.time() + 25
                while time.time() < deadline:
                    time.sleep(0.1)
                    try:
                        output = log_path.read_text(encoding="utf-8", errors="replace")
                    except OSError:
                        output = ""
                    if "event=listening" in output:
                        listening = True
                        break
                    if process.poll() is not None:
                        break
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
        try:
            output = log_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
        if listening:
            break
        if "address already in use" not in output.lower():
            break
    require(listening, f"bundled rdp-worker did not reach event=listening: {output[-800:]}")
    require("event=agent_ipc_listening" in output,
            f"bundled rdp-worker did not create the agent socket listener: {output[-800:]}")
    return f"listening on 127.0.0.1:{port} from a temp config, stopped with SIGTERM"


def nested_agent_executable(app):
    return app / "Contents/Helpers" / NESTED_AGENT_NAME / "Contents/MacOS" / NESTED_AGENT_EXECUTABLE


def agent_status_values(executable, working_directory, environment):
    completed = run([executable, "status"], cwd=working_directory, env=environment, timeout=60)
    output = completed.stdout + completed.stderr
    require(completed.returncode == 0, f"rdp-agent status exited {completed.returncode}: {output[-400:]}")
    screen = re.search(r"screen_recording=(granted|missing)", output)
    accessibility = re.search(r"accessibility=(granted|missing)", output)
    require(screen is not None, f"missing screen_recording=... in: {output[-400:]}")
    require(accessibility is not None, f"missing accessibility=... in: {output[-400:]}")
    return {"screen_recording": screen.group(1), "accessibility": accessibility.group(1)}


def check_agent_status(app, working_directory, environment):
    values = agent_status_values(nested_agent_executable(app), working_directory, environment)
    # Informational only: TCC grants are per machine and are not required here.
    return (f"informational: screen_recording={values['screen_recording']} "
            f"accessibility={values['accessibility']} (TCC state is per machine)")


def check_server_self_test_start(app, workspace):
    """Run --self-test with RDPSERVER_SELFTEST_START=1: the packaged worker starts,
    the nested agent delivers frames, and everything is cleaned up."""
    executable = app / "Contents/MacOS" / APP_EXECUTABLE
    environment = isolated_environment(workspace / "home-start", workspace / "tmp-start")
    environment["RDPSERVER_SELFTEST_START"] = "1"
    data_directory = workspace / "data-start"
    completed = run([executable, "--self-test", "--data-dir", str(data_directory)],
                    cwd=workspace, env=environment, timeout=240)
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        raise CheckFailure(
            f"RDPServer --self-test (RDPSERVER_SELFTEST_START=1) exited "
            f"{completed.returncode}: {output.strip()[:800] or '<no output>'}"
        )
    report = parse_single_json(completed.stdout)
    require(report.get("ok") is True, f"started self-test reported ok={report.get('ok')!r}")
    checks = {entry.get("name"): entry for entry in report.get("checks", []) if isinstance(entry, dict)}
    failed = [name for name, entry in checks.items() if entry.get("ok") is not True]
    require(not failed, f"self-test checks failed: {', '.join(failed)}")
    required = {
        "worker.started", "worker.listening", "worker.tcp_connect",
        "agent.frames", "cleanup.no_running_pids", "cleanup.socket_removed",
    }
    missing = sorted(required - set(checks))
    require(not missing, f"started self-test did not report checks: {', '.join(missing)}")
    # agent.frames may say "skipped: ..." on a machine without TCC; ok stays true.
    return (f"worker started+listened, agent frames ok "
            f"({checks['agent.frames'].get('detail') or 'no detail'}), cleanup verified")


def check_relocatable_copy(app, workspace, environment):
    """Simulate a drag-install: copy the app out of the DMG and run it there.

    /Applications lives outside the repo and the DMG volume, so this proves the
    bundle has no dependency on either location: helpers must resolve from the
    copy (source=bundle), the CLI must still work, and the nested agent must keep
    the same TCC/permission identity after the copy.
    """
    destination = workspace / "Applications" / APP_NAME
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(app, destination, symlinks=False)

    worker = destination / "Contents/Helpers/rdp-worker"
    completed = run([worker, "-config", str(workspace / "missing-copied-config.json")],
                    cwd=workspace, env=environment, timeout=60)
    output = (completed.stdout + completed.stderr).lower()
    require(completed.returncode != 0, "copied rdp-worker accepted a missing config")
    for symptom in ("library not loaded", "image not found", "dyld"):
        require(symptom not in output, f"copied rdp-worker hit a dyld error: {output[-400:]}")

    executable = destination / "Contents/MacOS" / APP_EXECUTABLE
    copy_data = workspace / "copy-status-data"
    status = run([executable, "--status", "--data-dir", str(copy_data)],
                 cwd=workspace, env=environment, timeout=60)
    require(status.returncode == 0,
            f"copied app --status exited {status.returncode}: {(status.stdout + status.stderr)[-500:]}")
    report = parse_single_json(status.stdout)
    require(report.get("ok") is True, f"copied app --status reported ok={report.get('ok')!r}")
    require(not copy_data.exists(), "copied app --status created the data directory")

    selftest_data = workspace / "copy-selftest-data"
    selftest = run([executable, "--self-test", "--data-dir", str(selftest_data)],
                   cwd=workspace, env=environment, timeout=240)
    combined = selftest.stdout + selftest.stderr
    require(selftest.returncode == 0,
            f"copied app --self-test exited {selftest.returncode}: {combined[-800:]}")
    selftest_report = parse_single_json(selftest.stdout)
    require(selftest_report.get("ok") is True,
            f"copied app --self-test reported ok={selftest_report.get('ok')!r}")
    require("source=bundle" in combined,
            f"copied app self-test did not resolve helpers from the bundle: {combined[-800:]}")
    helpers_line = next((line for line in combined.splitlines() if "helpers=" in line), "")
    require(str(destination) in helpers_line,
            f"copied app resolved helpers outside the copy: {helpers_line or '<no helpers line>'}")
    require(str(ROOT) not in combined, "copied app output references the repository path")
    require(".deps" not in combined, "copied app output references .deps")

    bundle_values = agent_status_values(nested_agent_executable(app), workspace, environment)
    copy_values = agent_status_values(nested_agent_executable(destination), workspace, environment)
    require(bundle_values == copy_values,
            f"nested agent permission state differs after copying: {bundle_values} vs {copy_values}")
    return (f"copied to Applications/: --status/--self-test ok (helpers source=bundle), "
            f"nested agent TCC query identical (screen_recording={copy_values['screen_recording']}, "
            f"accessibility={copy_values['accessibility']})")


def check_server_status(app, data_directory, environment):
    executable = app / "Contents/MacOS" / APP_EXECUTABLE
    existed_before = data_directory.exists()
    completed = run([executable, "--status", "--data-dir", str(data_directory)],
                    cwd=data_directory.parent, env=environment, timeout=60)
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        raise CheckFailure(
            f"RDPServer --status exited {completed.returncode}: {output.strip()[:600] or '<no output>'}"
        )
    report = parse_single_json(completed.stdout)
    reject_secret_keys(report)
    if not existed_before:
        require(not data_directory.exists(),
                "--status created the data directory; it must be read-only for status")
    if "data_directory" in report:
        reported = Path(str(report["data_directory"])).resolve()
        expected = data_directory.resolve()
        require(reported == expected or expected in reported.parents,
                f"report data_directory {report['data_directory']!r} is not the --data-dir temp path")
    worker = report.get("worker")
    if isinstance(worker, dict):
        require(worker.get("running") is False, f"--status reports a running worker: {worker}")
    return f"JSON ok={report.get('ok')} state={report.get('state')!r}"


def check_server_self_test(app, data_directory, environment):
    executable = app / "Contents/MacOS" / APP_EXECUTABLE
    completed = run([executable, "--self-test", "--data-dir", str(data_directory)],
                    cwd=data_directory.parent, env=environment, timeout=180)
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        raise CheckFailure(
            f"RDPServer --self-test exited {completed.returncode}: {output.strip()[:600] or '<no output>'}"
        )
    report = parse_single_json(completed.stdout)
    require(report.get("ok") is True, f"self-test reported ok={report.get('ok')!r}: {output.strip()[:400]}")
    return f"ok, {len(report.get('checks', []))} checks"


def check_live_data_dir_untouched(before, after):
    path = str(REAL_DATA_DIR)
    require(before.get(path) == after.get(path),
            f"the live data directory changed during verification: {path}")
    return f"{path} untouched"


def warn_runtime_noise(checker, before, after):
    """The repo .runtime is shared with the user's stopped LaunchAgent and other
    local harnesses, so a change there is reported but not attributed to the
    packaged app (the app runs with HOME/TMPDIR redirected and an explicit
    --data-dir)."""
    changed = [path for path, state in before.items() if after.get(path) != state]
    if changed:
        checker.warn("shared .runtime unchanged",
                     f"changed during the run (likely another process; not attributable): {', '.join(changed)}")
    else:
        checker.ok("shared .runtime unchanged", ".runtime untouched")
    if before.get(str(REAL_PREFERENCES)) != after.get(str(REAL_PREFERENCES)):
        checker.warn("preferences untouched", "com.rdp-server.server.plist changed (cfprefsd may persist defaults)")


def main():
    parser = argparse.ArgumentParser(description="Verify the packaged RDPServer.app / DMG")
    parser.add_argument("--dmg", default=str(DMG_PATH), help=f"DMG to verify (default: {DMG_PATH})")
    parser.add_argument("--no-build", action="store_true",
                        help="do not build the DMG when missing (fail instead)")
    parser.add_argument("--keep", action="store_true", help="keep the temp directory and mount")
    parser.add_argument("--skip-service-check", action="store_true",
                        help="skip the RDPSERVER_SELFTEST_START=1 run that briefly starts the "
                             "packaged worker and captures frames through the nested agent")
    arguments = parser.parse_args()

    checker = Checker()
    dmg_path = Path(arguments.dmg).resolve()
    try:
        ensure_dmg(dmg_path, arguments.no_build)
    except CheckFailure as error:
        checker.fail("dmg", str(error))
        print_summary(checker)
        return 1

    mounted = DmgMount(dmg_path)
    try:
        try:
            mounted.__enter__()
        except CheckFailure as error:
            checker.fail("dmg mounts", str(error))
            print_summary(checker)
            return 1

        mountpoint = mounted.mountpoint
        app = mountpoint / APP_NAME

        checker.run("dmg mounts", lambda: check_volume_label(mountpoint))
        checker.run("dmg contents", lambda: check_dmg_contents(mountpoint))
        checker.run("bundle layout", lambda: check_layout(app))
        checker.run("license files", lambda: check_licenses(app))
        checker.run("app Info.plist", lambda: check_info_plist(app))
        checker.run("nested agent Info.plist", lambda: check_nested_agent_plist(app))
        checker.run("codesign", lambda: check_codesign(app))
        checker.run("dylib relocation", lambda: check_relocation(app))

        workspace = mounted.temporary / "workspace"
        home = workspace / "home"
        temporary = workspace / "tmp"
        environment = isolated_environment(home, temporary)
        data_directory = workspace / "data"
        before = snapshot([REAL_DATA_DIR, REAL_PREFERENCES, LIVE_RUNTIME_DIR])

        checker.run("rdp-worker loads dylibs", lambda: check_worker_dyld(app, workspace, environment))
        checker.run("rdpctl loads dylibs", lambda: check_rdpctl_dyld(app, workspace, environment))
        checker.run("rdp-worker starts with temp config",
                    lambda: check_worker_startup(app, workspace, environment))
        checker.run("nested agent status", lambda: check_agent_status(app, workspace, environment))
        checker.run("relocatable copy (drag-install)",
                    lambda: check_relocatable_copy(app, workspace, environment))
        status_result = checker.run(
            "RDPServer --status", lambda: check_server_status(app, data_directory, environment)
        )
        if status_result is None:
            checker.skip("RDPServer --self-test", "--status is unavailable, so --self-test cannot be trusted yet")
        else:
            checker.run("RDPServer --self-test",
                        lambda: check_server_self_test(app, data_directory, environment))
            if arguments.skip_service_check:
                checker.skip("RDPServer --self-test starts service", "--skip-service-check")
            else:
                checker.run("RDPServer --self-test starts service",
                            lambda: check_server_self_test_start(app, workspace))
        after = snapshot([REAL_DATA_DIR, REAL_PREFERENCES, LIVE_RUNTIME_DIR])
        checker.run("live data dir untouched", lambda: check_live_data_dir_untouched(before, after))
        warn_runtime_noise(checker, before, after)
    finally:
        mounted.__exit__()
        if arguments.keep:
            print(f"temp directory kept at {mounted.temporary}")

    print_summary(checker)
    if checker.failures:
        return 1
    print("OK app bundle verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
