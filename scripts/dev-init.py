#!/usr/bin/env python3
"""Initialize a private loopback-only P0 store. Never stores a macOS password."""
import getpass
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
directory = root / ".runtime"
account = input("独立 RDP 测试账号（默认 alice）：").strip() or "alice"
if not re.fullmatch(r"[a-z0-9_.-]{1,64}", account):
    raise SystemExit("账号必须是 1..64 个小写字母、数字或 _.-")
if directory.is_symlink():
    raise SystemExit("拒绝使用符号链接作为凭据目录")
directory.mkdir(mode=0o700, exist_ok=True)
if directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077:
    raise SystemExit(".runtime 必须由当前用户拥有且权限为 0700")
if any(directory.iterdir()):
    raise SystemExit(".runtime 已有内容；请保留现有凭据，或先停止服务并手动移走目录")
password = getpass.getpass("设置独立 RDP 测试密码（不要输入 Mac 密码）：")
if not password or len(password.encode()) > 4095 or "\0" in password or "\n" in password:
    raise SystemExit("密码不能为空，最多 4095 UTF-8 字节")
if password != getpass.getpass("再次输入："):
    raise SystemExit("两次密码不一致")
os.umask(0o077)
hash_value = subprocess.run([str(root / "bin/rdpctl"), "hash-stdin"], input=password+"\n", text=True, capture_output=True, check=True).stdout.strip()
if not re.fullmatch(r"[0-9a-f]{32}", hash_value):
    raise SystemExit("WinPR 未返回有效 NT 哈希")
(directory / "sam").write_text(f"{account}:MACRDP::{hash_value}:\n")
openssl = Path(subprocess.check_output(["brew", "--prefix", "openssl@3"], text=True).strip()) / "bin/openssl"
subprocess.run([str(openssl), "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(directory / "key.pem"), "-out", str(directory / "cert.pem"), "-days", "7", "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
config = dict(address="127.0.0.1", port=3389, account=account, enabled=True, test_pattern=True, certificate=str(directory / "cert.pem"), key=str(directory / "key.pem"), sam=str(directory / "sam"))
(directory / "config.json").write_text(json.dumps(config, indent=2)+"\n")
profile = root / "test-pattern.rdp"
profile.write_text(f"full address:s:127.0.0.1:3389\nusername:s:MACRDP\\{account}\nscreen mode id:i:1\ndesktopwidth:i:800\ndesktopheight:i:600\nsession bpp:i:32\nenablecredsspsupport:i:1\nauthentication level:i:2\nredirectclipboard:i:0\n")
profile.chmod(0o600)
print("已创建私有凭据。运行 bin/rdp-worker，然后用 Windows App 打开项目根目录下的 test-pattern.rdp。")
