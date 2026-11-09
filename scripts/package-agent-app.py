#!/usr/bin/env python3
"""Package and ad-hoc sign the Agent as a stable macOS TCC app identity.

Also used by scripts/package-app-dmg.py to build the nested RDPAgent.app helper
inside dist/RDPServer.app, hence the optional binary/app/version arguments.
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


BUNDLE_ID = "com.rdp-server.agent"
DEFAULT_VERSION = "0.1.0"


def build_info_plist(version=DEFAULT_VERSION):
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "rdp-agent",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "RDP Agent",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "LSUIElement": True,
    }


def codesign_arguments(app_path):
    requirement = f'=designated => identifier "{BUNDLE_ID}"'
    return [
        "codesign", "--force", "--sign", "-", "--identifier", BUNDLE_ID,
        "--requirements", requirement, "--timestamp=none", str(app_path),
    ]


def package_agent(binary, app_path, version=DEFAULT_VERSION):
    binary = Path(binary).resolve()
    app_path = Path(app_path).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError(f"Agent executable is missing or not executable: {binary}")
    app_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rdp-agent-app-", dir=app_path.parent) as temporary:
        staged_app = Path(temporary) / app_path.name
        executable_dir = staged_app / "Contents/MacOS"
        executable_dir.mkdir(parents=True)
        shutil.copy2(binary, executable_dir / "rdp-agent")
        info_path = staged_app / "Contents/Info.plist"
        info_path.write_bytes(plistlib.dumps(build_info_plist(version), fmt=plistlib.FMT_XML))
        subprocess.run(codesign_arguments(staged_app), check=True, capture_output=True, text=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged_app)],
                       check=True, capture_output=True, text=True)

        if app_path.exists():
            current_info = app_path / "Contents/Info.plist"
            try:
                current = plistlib.loads(current_info.read_bytes())
            except (OSError, plistlib.InvalidFileException) as error:
                raise RuntimeError(f"refusing to replace unrecognized app bundle {app_path}: {error}") from error
            if current.get("CFBundleIdentifier") != BUNDLE_ID:
                raise RuntimeError(f"refusing to replace app with another bundle identifier: {app_path}")
            shutil.rmtree(app_path)
        os.replace(staged_app, app_path)
    return app_path


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Package and ad-hoc sign RDPAgent.app")
    parser.add_argument("--binary", default=str(root / "bin/rdp-agent"),
                        help="rdp-agent executable to bundle (default: bin/rdp-agent)")
    parser.add_argument("--app", default=str(root / "bin/RDPAgent.app"),
                        help="output app bundle path (default: bin/RDPAgent.app)")
    parser.add_argument("--version", default=DEFAULT_VERSION,
                        help=f"CFBundleShortVersionString (default: {DEFAULT_VERSION})")
    arguments = parser.parse_args()
    binary = Path(arguments.binary)
    app_path = Path(arguments.app)
    try:
        print(package_agent(binary, app_path, version=arguments.version))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None)
        print(f"package-agent-app: {detail or error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
