# macOS RDP Server

Use a Windows RDP client to control the desktop of the user already signed in to a
Mac. The project is an **early-stage prototype**, not a managed or notarized product.

> **Security and scope:** This does not provide remote macOS login, lock-screen or
> FileVault unlock, multiple-user sessions, public-internet access, audio, or drive
> redirection. By default the server listens only on `127.0.0.1`. LAN access must be
> explicitly enabled and is limited to one private IPv4 address. Do not expose it to
> the public internet.

## What works

- HYBRID NLA authentication with a dedicated RDP password (not the Mac password).
- One active RDP session controlling the currently logged-in Mac user's desktop.
- Screen capture, keyboard and mouse input, and bidirectional text and file clipboard.
- Resolution matching on connection using a virtual display when supported.
- A menu bar app that manages the worker and agent, permissions, and configuration.

The primary manually tested client is Windows 11 `mstsc.exe`; macOS Microsoft Windows
App has also been tested. AVC420/H.264 remains experimental and is not in the default
build. See [current status and limitations](docs/STATUS-2026-11-08.md) for evidence and
details. A configured 60 fps target is not a claim of 60 fps client-rendered video.

## Download and install

Download the latest `.dmg` from the project's
[GitHub Releases](https://github.com/jiayaoO3O/macos-rdp-server/releases). The app is
ad-hoc signed and not notarized, so macOS may require you to approve opening it. Only
install software you trust.

1. Open the DMG and drag `RDPServer.app` to Applications.
2. Launch the app and set a dedicated RDP username and password.
3. Grant Screen Recording and Accessibility permissions to the bundled `RDPAgent.app`
   when prompted. Full Disk Access is optional and only needed to read protected files
   through file clipboard.
4. Enable LAN access only if another device must connect. The app displays the address
   to use; the default is local-only.
5. From Windows, connect with `mstsc.exe` to the displayed address and port (default
   `3389`), using `MACRDP\<username>`. Review and accept the self-signed certificate
   only if you trust this Mac.

For troubleshooting, migration, and rollback guidance, see the
[user setup notes](docs/STATUS-2026-11-08.md) and the app's `--status` / `--self-test`
commands.

## Build from source

### Requirements

- Apple Silicon Mac running macOS 14.0 or later
- Xcode Command Line Tools, Go 1.27+, CMake 4.x, Python 3.9+
- Homebrew `openssl@3`, `json-c`, and `pkgconf`

The first dependency build downloads the pinned FreeRDP/WinPR 3.32.2 source archive.
See [dependency and licensing details](docs/DEPENDENCIES.md).

```sh
make deps          # Download, verify, and build FreeRDP into .deps/install
make app-dmg       # Build dist/RDPServer.app and the versioned DMG
make test-app-bundle
```

For worker/agent development and the complete test matrix, see
[contributor guidance](AGENTS.md) and the [documentation index](docs/README.md).

## Project documentation

- [Current status, supported scope, limitations, and verification](docs/STATUS-2026-11-08.md)
- [Dependencies, build configuration, and third-party licenses](docs/DEPENDENCIES.md)
- [Design, diagnosis, and verification index](docs/README.md)
- [Contributor and coding-agent guidelines](AGENTS.md)
- [Project license](LICENSE) · [Notices](NOTICE) · [Third-party notices](THIRD-PARTY-NOTICES.md)

Historical design and validation records are retained for traceability; their dated
results are not statements of current behavior. The repository currently has no CI,
so test results must be produced locally and described with their verification level.

## Contributing and security

Read [AGENTS.md](AGENTS.md) before changing code or protocol behavior. Run the checks
relevant to your changes; `make check` is the baseline, with protocol and packaging
checks required for their respective areas. Do not include credentials, private
configuration, logs containing sensitive data, or build artifacts in issues or commits.

Report security issues privately through GitHub Security Advisories rather than in a
public issue.
