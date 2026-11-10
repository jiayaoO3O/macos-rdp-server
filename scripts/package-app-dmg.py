#!/usr/bin/env python3
"""Assemble dist/RDPServer.app and build the drag-install DMG.

Bundle contract (authoritative: docs/DESIGN-2026-11-08-app-packaging.md):

    dist/RDPServer.app/
      Contents/Info.plist            com.rdp-server.server, menu bar (LSUIElement)
      Contents/MacOS/RDPServer       SwiftPM release product
      Contents/Helpers/rdp-worker    fresh Go build from ./cmd/rdp-worker
      Contents/Helpers/rdpctl        fresh Go build from ./cmd/rdpctl
      Contents/Helpers/RDPAgent.app  nested agent bundle (com.rdp-server.agent)
      Contents/Frameworks/*.dylib    FreeRDP / OpenSSL / json-c, @rpath-relocated
      Contents/Resources/AppIcon.icns
      Contents/Resources/Licenses/  LICENSE / NOTICE / THIRD-PARTY-NOTICES.md

The script never reads or writes bin/ (the deployed artifacts) and never touches
.runtime/. Go binaries are built into dist/build/, the DMG into dist/.

stdlib only.
"""

import argparse
import hashlib
import importlib.util
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
BUILD_DIR = DIST / "build"
APP_PATH = DIST / "RDPServer.app"
STAGING_DIR = DIST / "dmg-staging"

APP_NAME = "RDPServer.app"
APP_EXECUTABLE = "RDPServer"
BUNDLE_ID = "com.rdp-server.server"
DISPLAY_NAME = "RDP Server"
VERSION = "0.2.3"
BUILD_NUMBER = "1"
MINIMUM_SYSTEM_VERSION = "14.0"
# Every bundled Mach-O must be loadable on macOS 26; the dev machine runs a
# newer macOS, so third-party bottles and cgo outputs are normalized to this.
TARGET_MINOS = "14.0"
VOLUME_NAME = "RDP Server"
DMG_PATH = DIST / f"RDPServer-{VERSION}.dmg"

SWIFT_RELEASE = ROOT / "native/macos/.build/release"
DEPS_PREFIX = Path(os.environ.get("FREERDP_INSTALL_PREFIX", ROOT / ".deps/install"))
DEPS_LIB = DEPS_PREFIX / "lib"

# Relative to dist/RDPServer.app/Contents (paths below reuse these as children).
MACOS_DIR = "MacOS"
HELPERS_DIR = "Helpers"
FRAMEWORKS_DIR = "Frameworks"
HELPER_NAMES = ("rdp-worker", "rdpctl")
NESTED_AGENT_NAME = "RDPAgent.app"
NESTED_AGENT_EXECUTABLE = "rdp-agent"
FRAMEWORKS_RPATH = "@executable_path/../Frameworks"
RESOURCES_DIR = "Resources"
APP_ICON_NAME = "AppIcon"
APP_ICON_SOURCE = ROOT / "native/macos/Resources" / "AppIcon.icns"
# Distributed inside the bundle for license compliance: Apache-2.0 (this
# project) plus the bundled FreeRDP/WinPR, OpenSSL and json-c notices.
LICENSES_DIR = "Licenses"
LICENSE_FILES = ("LICENSE", "NOTICE", "THIRD-PARTY-NOTICES.md")

# Anything under these prefixes is provided by macOS and must not be bundled.
SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Apple/")


def run(command, *, cwd=None, env=None, echo=True, check=True):
    rendered = " ".join(str(part) for part in command)
    if echo:
        print(f"  $ {rendered}")
    completed = subprocess.run(
        [str(part) for part in command],
        cwd=str(cwd) if cwd else None,
        env=env,
        capture_output=True,
        text=True,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"command failed (exit {completed.returncode}): {rendered}\n"
            f"{completed.stdout}{completed.stderr}"
        )
    return completed


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_system_path(path):
    return path.startswith(SYSTEM_PREFIXES)


def otool_deps(path):
    output = run(["otool", "-L", str(path)], echo=False).stdout
    dependencies = []
    for line in output.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        dependency = line.split(" (compatibility version", 1)[0].strip()
        if dependency:
            dependencies.append(dependency)
    return dependencies


def otool_dylib_id(path):
    output = run(["otool", "-D", str(path)], echo=False).stdout
    entries = [line.strip() for line in output.splitlines() if line.strip()]
    return entries[1] if len(entries) > 1 else None


def otool_rpaths(path):
    output = run(["otool", "-l", str(path)], echo=False).stdout
    lines = output.splitlines()
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


def info_plist():
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": APP_EXECUTABLE,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": DISPLAY_NAME,
        "CFBundleDisplayName": DISPLAY_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD_NUMBER,
        "CFBundleIconFile": APP_ICON_NAME,
        "LSMinimumSystemVersion": MINIMUM_SYSTEM_VERSION,
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "LSApplicationCategoryType": "public.app-category.utilities",
    }


def load_agent_packager():
    """Import scripts/package-agent-app.py (hyphens prevent a plain import)."""
    module_path = ROOT / "scripts/package-agent-app.py"
    spec = importlib.util.spec_from_file_location("package_agent_app", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_swift():
    print("==> swift build -c release --package-path native/macos")
    run(["swift", "build", "-c", "release", "--package-path", "native/macos"], cwd=ROOT)


def build_go_binaries(skip):
    if skip:
        print("==> reusing Go binaries in dist/build")
    else:
        print(f"==> go build -o {BUILD_DIR}/ ./cmd/... (minimum macOS {TARGET_MINOS})")
        BUILD_DIR.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ,
                   MACOSX_DEPLOYMENT_TARGET=TARGET_MINOS,
                   CGO_CFLAGS=f"-mmacosx-version-min={TARGET_MINOS}",
                   CGO_LDFLAGS=f"-mmacosx-version-min={TARGET_MINOS}")
        run(["go", "build", "-o", str(BUILD_DIR) + os.sep, "./cmd/..."], cwd=ROOT, env=env)
    for name in HELPER_NAMES:
        binary = BUILD_DIR / name
        if not binary.is_file():
            raise RuntimeError(f"missing Go helper {binary}; run without --skip-go-build")
        print(f"    {name}: {binary.stat().st_size} bytes")


def copy_license_files(contents):
    """Copy LICENSE / NOTICE / THIRD-PARTY-NOTICES.md into Resources/Licenses.

    Must run before sign_bundle(): code signing covers Resources, so these files
    have to be final when the bundle is signed. Rebuilding starts from a fresh
    bundle (assemble_app removes the old one), so this is idempotent. A missing
    or empty source file, or a copy whose sha256 differs from the source, is a
    hard error: the distributed app must carry the Apache-2.0 text and the
    third-party notices byte-for-byte.
    """
    destination = contents / RESOURCES_DIR / LICENSES_DIR
    destination.mkdir(parents=True, exist_ok=True)
    for name in LICENSE_FILES:
        source = ROOT / name
        if not source.is_file():
            raise RuntimeError(f"missing license file {source}")
        if source.stat().st_size == 0:
            raise RuntimeError(f"empty license file {source}")
        target = destination / name
        shutil.copy2(source, target)
        if target.stat().st_size == 0:
            raise RuntimeError(f"copied license file is empty: {target}")
        source_sha = file_sha256(source)
        target_sha = file_sha256(target)
        if target_sha != source_sha:
            raise RuntimeError(
                f"license copy mismatch for {name}: bundle sha256 {target_sha} != source sha256 "
                f"{source_sha} ({target.stat().st_size} vs {source.stat().st_size} bytes)")
        print(f"    license: {LICENSES_DIR}/{name} "
              f"({target.stat().st_size} bytes, sha256 {source_sha[:12]}\u2026)")


def assemble_app():
    print(f"==> assembling {APP_PATH}")
    executable = SWIFT_RELEASE / APP_EXECUTABLE
    if not executable.is_file():
        raise RuntimeError(
            f"missing SwiftPM release product {executable}; run 'make app-build' or pass --swift-build"
        )
    agent_executable = SWIFT_RELEASE / NESTED_AGENT_EXECUTABLE
    if not agent_executable.is_file():
        raise RuntimeError(
            f"missing SwiftPM release product {agent_executable}; run 'make app-build' or pass --swift-build"
        )

    if APP_PATH.exists():
        print(f"    removing previous bundle {APP_PATH}")
        shutil.rmtree(APP_PATH)
    contents = APP_PATH / "Contents"
    for directory in (MACOS_DIR, HELPERS_DIR, FRAMEWORKS_DIR, RESOURCES_DIR):
        (contents / directory).mkdir(parents=True, exist_ok=True)

    shutil.copy2(executable, contents / MACOS_DIR / APP_EXECUTABLE)
    (contents / MACOS_DIR / APP_EXECUTABLE).chmod(0o755)
    if not APP_ICON_SOURCE.is_file():
        raise RuntimeError(f"missing app icon {APP_ICON_SOURCE}")
    shutil.copy2(APP_ICON_SOURCE, contents / RESOURCES_DIR / (APP_ICON_NAME + ".icns"))
    print(f"    icon: {APP_ICON_SOURCE.name}")
    copy_license_files(contents)
    for name in HELPER_NAMES:
        target = contents / HELPERS_DIR / name
        shutil.copy2(BUILD_DIR / name, target)
        target.chmod(0o755)

    agent_packager = load_agent_packager()
    nested_agent = contents / HELPERS_DIR / NESTED_AGENT_NAME
    agent_packager.package_agent(agent_executable, nested_agent, version=VERSION)
    print(f"    nested agent: {nested_agent}")

    (contents / "Info.plist").write_bytes(plistlib.dumps(info_plist(), fmt=plistlib.FMT_XML))
    print(f"    Info.plist: {BUNDLE_ID} {VERSION} ({BUILD_NUMBER})")


def resolve_dependency(dependency, referencing_macho, search_dirs):
    """Resolve one otool dependency to a source file to bundle."""
    if dependency.startswith("@rpath/"):
        name = dependency[len("@rpath/"):]
        for directory in search_dirs:
            candidate = directory / name
            if candidate.is_file():
                return candidate.resolve()
        searched = ", ".join(str(directory) for directory in search_dirs)
        raise RuntimeError(f"cannot resolve {dependency} of {referencing_macho} (searched {searched})")
    if dependency.startswith("@loader_path/") or dependency.startswith("@executable_path/"):
        _, _, relative = dependency.partition("/")
        roots = [referencing_macho.parent]
        if dependency.startswith("@executable_path/"):
            roots = [referencing_macho.parent, referencing_macho.parent.parent]
        for root in roots:
            candidate = (root / relative).resolve()
            if candidate.is_file():
                return candidate
        raise RuntimeError(f"cannot resolve {dependency} of {referencing_macho}")
    path = Path(dependency)
    if path.is_file():
        return path.resolve()
    raise RuntimeError(f"missing dependency {dependency} of {referencing_macho}")


def bundle_dylibs(contents):
    """Copy every non-system transitive dylib into Contents/Frameworks."""
    print("==> bundling non-system dylibs into Contents/Frameworks")
    frameworks = contents / FRAMEWORKS_DIR
    search_dirs = [DEPS_LIB, frameworks, SWIFT_RELEASE]
    pending = [contents / HELPERS_DIR / name for name in HELPER_NAMES]
    pending.append(
        contents / HELPERS_DIR / NESTED_AGENT_NAME / "Contents" / MACOS_DIR / NESTED_AGENT_EXECUTABLE
    )
    sources = {}
    while pending:
        macho = pending.pop(0)
        for dependency in otool_deps(macho):
            if is_system_path(dependency):
                continue
            name = Path(dependency).name
            source = resolve_dependency(dependency, macho, search_dirs)
            if name in sources:
                if file_sha256(sources[name]) != file_sha256(source):
                    raise RuntimeError(
                        f"conflicting copies of {name}: {sources[name]} and {source}"
                    )
                continue
            target = frameworks / name
            shutil.copy2(source, target)
            target.chmod(0o755)
            sources[name] = source
            pending.append(target)
            print(f"    {name} <- {source}")
    if not sources:
        raise RuntimeError("no non-system dylibs found; rdp-worker/rdpctl linkage changed unexpectedly")
    return sorted(sources)


def rewrite_executable(path):
    """Point an executable at @rpath/<basename> and drop repo/.deps rpaths."""
    dependencies = [dep for dep in otool_deps(path) if not is_system_path(dep)]
    rpaths = otool_rpaths(path)
    for dependency in dependencies:
        expected = f"@rpath/{Path(dependency).name}"
        if dependency != expected:
            run(["install_name_tool", "-change", dependency, expected, str(path)], echo=False)
    for rpath in rpaths:
        if "/.deps/" in rpath or rpath == str(ROOT) or rpath.startswith(str(ROOT) + "/"):
            print(f"    dropping rpath {rpath} from {path.name}")
            run(["install_name_tool", "-delete_rpath", rpath, str(path)], echo=False)
    if FRAMEWORKS_RPATH not in otool_rpaths(path):
        run(["install_name_tool", "-add_rpath", FRAMEWORKS_RPATH, str(path)], echo=False)


def rewrite_dylib(path):
    """Give a bundled dylib an @rpath id and @rpath inter-dependencies."""
    dependencies = otool_deps(path)
    current_id = otool_dylib_id(path)
    for dependency in dependencies:
        expected = f"@rpath/{Path(dependency).name}"
        if dependency == expected or dependency == current_id:
            continue
        if is_system_path(dependency):
            continue
        run(["install_name_tool", "-change", dependency, expected, str(path)], echo=False)
    expected_id = f"@rpath/{path.name}"
    if current_id and current_id != expected_id:
        run(["install_name_tool", "-id", expected_id, str(path)], echo=False)


def version_tuple(text):
    return tuple(int(part) for part in text.split(".") if part.isdigit())


def macho_minos(path):
    """Minimum macOS version recorded in LC_BUILD_VERSION (None if absent)."""
    output = run(["vtool", "-show-build", str(path)], echo=False, check=False).stdout
    for line in output.splitlines():
        match = re.match(r"\s*minos\s+([0-9.]+)", line)
        if match:
            return match.group(1)
    return None


def normalize_minimum_versions():
    """Rewrite Mach-O minimum macOS versions down to TARGET_MINOS.

    SwiftPM products already carry 14.0, but Go/cgo helpers and third-party
    bottles (Homebrew OpenSSL/json-c; FreeRDP if built without an explicit
    deployment target) carry the build machine's newer minos, which makes the
    app refuse to launch (or refuse to spawn rdpctl when saving credentials)
    on the target macOS 26. vtool only rewrites LC_BUILD_VERSION - the code is
    untouched - and every rewritten file is ad-hoc re-signed below.
    """
    print("==> normalizing Mach-O minimum macOS versions")
    contents = APP_PATH / "Contents"
    frameworks = contents / FRAMEWORKS_DIR
    targets = [
        contents / MACOS_DIR / APP_EXECUTABLE,
        contents / HELPERS_DIR / "rdp-worker",
        contents / HELPERS_DIR / "rdpctl",
        contents / HELPERS_DIR / NESTED_AGENT_NAME / "Contents" / MACOS_DIR / NESTED_AGENT_EXECUTABLE,
    ]
    targets += sorted(frameworks.glob("*.dylib"))
    target = version_tuple(TARGET_MINOS)
    for path in targets:
        minos = macho_minos(path)
        if minos is None or version_tuple(minos) <= target:
            continue
        if NESTED_AGENT_NAME in str(path):
            raise RuntimeError(
                f"{path} needs macOS {minos}; the nested agent must be built for {TARGET_MINOS}"
            )
        temp = path.with_name(path.name + ".minos")
        run(["vtool", "-set-build-version", "macos", TARGET_MINOS, TARGET_MINOS,
             "-replace", "-output", str(temp), str(path)], echo=False)
        os.chmod(temp, path.stat().st_mode & 0o777)
        temp.replace(path)
        print(f"    {path.name}: minos {minos} -> {TARGET_MINOS}")


def relocate_dylibs():
    print("==> relocating dylib references (@rpath)")
    contents = APP_PATH / "Contents"
    bundled = bundle_dylibs(contents)
    frameworks = contents / FRAMEWORKS_DIR
    for name in HELPER_NAMES:
        executable = contents / HELPERS_DIR / name
        rewrite_executable(executable)
        print(f"    {name}: rpath {FRAMEWORKS_RPATH}")
    for name in bundled:
        rewrite_dylib(frameworks / name)
    return bundled


def adhoc_sign(path):
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)], echo=False)


def strip_dev_rpaths(path):
    """Drop build-machine toolchain rpaths (SwiftPM only needs @loader_path and
    /usr/lib/swift at runtime; /Library/Developer/... would not exist on a Mac
    without the command line tools). Returns True when the file changed."""
    changed = False
    for rpath in otool_rpaths(path):
        if rpath.startswith("@"):
            continue
        if is_system_path(rpath):
            continue
        print(f"    dropping dev rpath {rpath} from {path.name}")
        run(["install_name_tool", "-delete_rpath", rpath, str(path)], echo=False)
        changed = True
    return changed


def strip_unneeded_rpaths():
    """Remove dev-toolchain rpaths and re-sign the nested agent with its own identity."""
    print("==> stripping command-line-tool rpaths from Swift binaries")
    contents = APP_PATH / "Contents"
    strip_dev_rpaths(contents / MACOS_DIR / APP_EXECUTABLE)

    nested_agent = contents / HELPERS_DIR / NESTED_AGENT_NAME
    nested_executable = nested_agent / "Contents" / MACOS_DIR / NESTED_AGENT_EXECUTABLE
    if strip_dev_rpaths(nested_executable):
        # install_name_tool invalidated the nested signature: re-sign with the
        # agent's own identifier/requirements so the TCC identity survives.
        agent_packager = load_agent_packager()
        run(agent_packager.codesign_arguments(nested_agent))
        run(["codesign", "--verify", "--deep", "--strict", str(nested_agent)], echo=False)
        print(f"    re-signed {NESTED_AGENT_NAME} as com.rdp-server.agent")


def codesign_identifier(path):
    completed = run(["codesign", "-dvv", str(path)], echo=False, check=False)
    for line in (completed.stdout + completed.stderr).splitlines():
        if line.startswith("Identifier="):
            return line.split("=", 1)[1].strip()
    return None


def sign_bundle():
    """Sign nested code first, then the outer bundle without --deep.

    The nested RDPAgent.app keeps its own com.rdp-server.agent identity (TCC
    identity for permissions): package-agent-app.py signed it when it was
    assembled, and re-signing it with --deep would rewrite that identifier.
    Only Mach-O files changed by install_name_tool (helpers, bundled dylibs)
    are re-signed here.
    """
    print("==> codesigning (ad-hoc, nested-first)")
    contents = APP_PATH / "Contents"
    nested_agent = contents / HELPERS_DIR / NESTED_AGENT_NAME
    identifier = codesign_identifier(nested_agent)
    if identifier != "com.rdp-server.agent":
        raise RuntimeError(f"nested agent identifier is {identifier!r}, expected com.rdp-server.agent")
    print(f"    nested {NESTED_AGENT_NAME} (Identifier={identifier}, kept)")
    for dylib in sorted((contents / FRAMEWORKS_DIR).glob("*.dylib")):
        adhoc_sign(dylib)
        print(f"    {dylib.name}")
    for name in HELPER_NAMES:
        adhoc_sign(contents / HELPERS_DIR / name)
        print(f"    {name}")
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(APP_PATH)])
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(APP_PATH)], echo=False)
    outer_identifier = codesign_identifier(APP_PATH)
    if outer_identifier != BUNDLE_ID:
        raise RuntimeError(f"outer identifier is {outer_identifier!r}, expected {BUNDLE_ID}")
    print(f"    outer {APP_NAME} (Identifier={outer_identifier}, deep-verified)")


def license_layout_problems(contents):
    """Problems with the shipped Resources/Licenses files (empty list = OK).

    The expected bytes/sha256 come from the current repository root files, so a
    bundle built from a different license revision fails before the DMG exists.
    """
    problems = []
    licenses_dir = contents / RESOURCES_DIR / LICENSES_DIR
    for name in LICENSE_FILES:
        license_file = licenses_dir / name
        source = ROOT / name
        if not license_file.is_file():
            problems.append(f"missing Resources/{LICENSES_DIR}/{name}")
            continue
        actual_size = license_file.stat().st_size
        actual_sha = file_sha256(license_file)
        if not source.is_file():
            problems.append(
                f"cannot verify Resources/{LICENSES_DIR}/{name}: repo root {name} is missing")
            continue
        expected_size = source.stat().st_size
        expected_sha = file_sha256(source)
        if actual_sha != expected_sha:
            problems.append(
                f"Resources/{LICENSES_DIR}/{name} sha256 {actual_sha} != repo {name} sha256 "
                f"{expected_sha} ({actual_size} vs {expected_size} bytes)")
    return problems


def verify_layout():
    """Fail before the DMG if any absolute or unresolvable reference remains."""
    print("==> verifying bundle layout")
    contents = APP_PATH / "Contents"
    frameworks = contents / FRAMEWORKS_DIR
    framework_names = {path.name for path in frameworks.glob("*.dylib")}
    if not framework_names:
        raise RuntimeError("Contents/Frameworks is empty")

    checked = [
        contents / MACOS_DIR / APP_EXECUTABLE,
        contents / HELPERS_DIR / "rdp-worker",
        contents / HELPERS_DIR / "rdpctl",
    ]
    checked += [frameworks / name for name in sorted(framework_names)]
    checked.append(
        contents / HELPERS_DIR / NESTED_AGENT_NAME / "Contents" / MACOS_DIR / NESTED_AGENT_EXECUTABLE
    )

    problems = []
    for macho in checked:
        for dependency in otool_deps(macho):
            if is_system_path(dependency):
                continue
            if not dependency.startswith("@rpath/"):
                problems.append(f"{macho.name}: absolute non-system dependency {dependency}")
                continue
            name = dependency[len("@rpath/"):]
            if name not in framework_names:
                problems.append(f"{macho.name}: {dependency} is not bundled in Contents/Frameworks")
        if macho.suffix == ".dylib":
            identifier = otool_dylib_id(macho)
            if identifier and not identifier.startswith("@rpath/"):
                problems.append(f"{macho.name}: absolute install id {identifier}")
        for rpath in otool_rpaths(macho):
            if "/.deps/" in rpath or rpath == str(ROOT) or rpath.startswith(str(ROOT) + "/"):
                problems.append(f"{macho.name}: repo rpath {rpath}")
            elif rpath.startswith("/Library/Developer/"):
                problems.append(f"{macho.name}: dev-toolchain rpath {rpath}")

    for name in HELPER_NAMES:
        rpaths = otool_rpaths(contents / HELPERS_DIR / name)
        if FRAMEWORKS_RPATH not in rpaths:
            problems.append(f"{name}: missing rpath {FRAMEWORKS_RPATH}")

    problems.extend(license_layout_problems(contents))

    nested_info_path = contents / HELPERS_DIR / NESTED_AGENT_NAME / "Contents" / "Info.plist"
    nested_info = plistlib.loads(nested_info_path.read_bytes())
    if nested_info.get("CFBundleIdentifier") != "com.rdp-server.agent":
        problems.append(f"nested agent bundle id is {nested_info.get('CFBundleIdentifier')!r}")
    if nested_info.get("CFBundleExecutable") != NESTED_AGENT_EXECUTABLE:
        problems.append(f"nested agent executable is {nested_info.get('CFBundleExecutable')!r}")

    if problems:
        raise RuntimeError("bundle verification failed:\n  " + "\n  ".join(problems))

    total = sum(path.stat().st_size for path in frameworks.glob("*.dylib"))
    print(f"    {len(framework_names)} dylibs ({total} bytes), all non-system deps @rpath-resolved")
    print(f"    helpers carry rpath {FRAMEWORKS_RPATH}; nested agent id com.rdp-server.agent")


def create_dmg():
    print(f"==> staging drag-install DMG ({DMG_PATH.name})")
    if STAGING_DIR.exists():
        shutil.rmtree(STAGING_DIR)
    STAGING_DIR.mkdir(parents=True)
    shutil.copytree(APP_PATH, STAGING_DIR / APP_NAME, symlinks=True)
    os.symlink("/Applications", STAGING_DIR / "Applications")
    if DMG_PATH.exists():
        DMG_PATH.unlink()
    run([
        "hdiutil", "create",
        "-volname", VOLUME_NAME,
        "-srcfolder", str(STAGING_DIR),
        "-fs", "HFS+",
        "-format", "UDZO",
        "-ov",
        str(DMG_PATH),
    ])
    run(["hdiutil", "verify", str(DMG_PATH)], echo=False)
    print(f"    {DMG_PATH} ({DMG_PATH.stat().st_size} bytes)")
    print(f"    sha256 {file_sha256(DMG_PATH)}")


def main():
    parser = argparse.ArgumentParser(description="Assemble dist/RDPServer.app and the drag-install DMG")
    parser.add_argument("--swift-build", action="store_true",
                        help="run 'swift build -c release' before assembling")
    parser.add_argument("--skip-go-build", action="store_true",
                        help="reuse the Go helpers already present in dist/build")
    parser.add_argument("--skip-dmg", action="store_true",
                        help="assemble and sign the app bundle only")
    arguments = parser.parse_args()

    try:
        if arguments.swift_build:
            build_swift()
        build_go_binaries(arguments.skip_go_build)
        assemble_app()
        relocate_dylibs()
        strip_unneeded_rpaths()
        normalize_minimum_versions()
        sign_bundle()
        verify_layout()
        if not arguments.skip_dmg:
            create_dmg()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None)
        print(f"package-app-dmg: {detail or error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
