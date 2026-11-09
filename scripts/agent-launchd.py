#!/usr/bin/env python3
"""Install or inspect the per-user persistent desktop Agent LaunchAgent."""

import argparse
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


LABEL = "com.rdp-server.agent"


def build_job(root, socket_path=None, display_index=0):
    root = Path(root).resolve()
    runtime = root / ".runtime"
    socket_path = Path(socket_path) if socket_path else runtime / "agent.sock"
    if not socket_path.is_absolute():
        socket_path = root / socket_path
    return {
        "Label": LABEL,
        "ProgramArguments": [
            str(root / "scripts/run-agent-stream.sh"),
            str(root / "bin/RDPAgent.app/Contents/MacOS/rdp-agent"),
            str(socket_path),
            str(display_index),
            str(runtime),
        ],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "ProcessType": "Background",
        "WorkingDirectory": str(root),
        "StandardOutPath": str(runtime / "agent-launchd.log"),
        "StandardErrorPath": str(runtime / "agent-launchd.log"),
        "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    }


def launchctl(*arguments):
    return subprocess.run(["launchctl", *arguments], text=True, capture_output=True)


def job_path():
    return Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"


def install(job):
    path = job_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = plistlib.dumps(job, fmt=plistlib.FMT_XML, sort_keys=True)
    if path.exists():
        try:
            existing = plistlib.loads(path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            raise RuntimeError(f"refusing to replace unreadable plist {path}: {error}") from error
        if existing != job:
            raise RuntimeError(f"refusing to overwrite a different LaunchAgent at {path}")
    else:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{LABEL}.", delete=False) as file:
            temporary = Path(file.name)
            file.write(payload)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)

    domain = f"gui/{os.getuid()}"
    loaded = launchctl("print", f"{domain}/{LABEL}").returncode == 0
    result = launchctl("kickstart", "-k", f"{domain}/{LABEL}") if loaded else launchctl("bootstrap", domain, str(path))
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "launchctl failed")
    return path


def uninstall():
    path = job_path()
    domain = f"gui/{os.getuid()}"
    if launchctl("print", f"{domain}/{LABEL}").returncode == 0:
        result = launchctl("bootout", domain, str(path))
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "launchctl bootout failed")
    if path.exists():
        try:
            existing = plistlib.loads(path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            raise RuntimeError(f"refusing to remove unreadable plist {path}: {error}") from error
        if existing.get("Label") != LABEL:
            raise RuntimeError(f"refusing to remove plist with unexpected label: {path}")
        path.unlink()
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("print", "install", "status", "uninstall"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--socket", type=Path, help="Worker Agent socket (default: .runtime/agent.sock)")
    parser.add_argument("--display", type=int, default=0)
    args = parser.parse_args()
    if args.display < 0:
        parser.error("display index must not be negative")
    try:
        job = build_job(args.root, args.socket, args.display)
        if args.action == "print":
            sys.stdout.buffer.write(plistlib.dumps(job, fmt=plistlib.FMT_XML, sort_keys=True))
        elif args.action == "install":
            print(f"installed {install(job)}")
        elif args.action == "uninstall":
            print(f"uninstalled {uninstall()}")
        else:
            result = launchctl("print", f"gui/{os.getuid()}/{LABEL}")
            if result.returncode:
                print("not loaded")
                return 1
            print(result.stdout)
    except (OSError, RuntimeError) as error:
        print(f"agent-launchd: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
