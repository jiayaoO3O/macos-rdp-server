# 依赖与版本（DEPENDENCIES）

> 面向**首次构建**或**升级依赖**的开发者：本文给出依赖/版本矩阵、构建顺序与产物、第三方许可证与合规说明、可复现性边界。
>
> **最后核对**：2026-11-09，macOS 27.2 / Apple Silicon 开发机，按当前工作区文件逐项实测。**本项目没有 CI**，构建与测试需在本地手工运行。
>
> **口径**：每条版本/选项都标注可核对的仓库文件。引用优先用「文件 + 函数/常量/目标名」而非行号（脚本与文档仍在演进，行号会漂移）；少数保留的行号以当前工作区为准，文件变动后以代码为准。「下限」= 构建/运行要求；「本机实测」= 当前开发机的实际版本，**不是**要求。仓库文件无法证明的内容标「未验证」。
>
> **维护**：修改 `Makefile`、`scripts/build-freerdp.sh`、`native/macos/Package.swift`、`scripts/package-app-dmg.py` 或 `THIRD-PARTY-NOTICES.md`，或升级 FreeRDP / 版本号时，请同步更新本文。

## 0. 30 秒版

- **必需**：Apple Silicon + macOS 14.0+、Xcode Command Line Tools（不需要完整 Xcode）、Go 1.27、CMake、Homebrew `openssl@3`。
- **唯一联网构建步骤**是 `make deps`：从 GitHub Release 下载 FreeRDP/WinPR 3.32.2（约 11 MB，SHA-256 固定）并用 CMake 构建到 `.deps/install`。其余构建/测试/打包全离线。
- `.deps/install` 缺失时 cgo 会直接编译失败；`make build` 等目标**不会**自动触发 `make deps`。
- FFmpeg 只服务于实验性的 AVC420 路径，**可选**，默认产品不含。
- DMG 内分发 7 个第三方动态库，并随包带 `LICENSE`/`NOTICE`/`THIRD-PARTY-NOTICES.md` 副本（`Contents/Resources/Licenses/`）；合规义务与验证命令见 §8。
- 同一台机器、同一 Homebrew 状态可重建；**不是**逐字节可复现，也不是"换机器开箱即得"（§9）。

## 1. 依赖一览

| 依赖 | 版本（下限 / 本机实测） | 权威声明位置 | 用途 | 必需性 | 验证方式 |
| --- | --- | --- | --- | --- | --- |
| 操作系统 | 下限 **macOS 14.0**；目标机 macOS 26；开发机 macOS 27.2 | `native/macos/Package.swift`（`platforms` 声明）、`Makefile`（`MACOSX_DEPLOYMENT_TARGET`/`CGO_CFLAGS`/`CGO_LDFLAGS`）、`scripts/build-freerdp.sh`（CMake 的 SDK/架构/部署目标选项）、`scripts/package-app-dmg.py`（`MINIMUM_SYSTEM_VERSION`/`TARGET_MINOS`） | 运行/部署目标 | 必需 | `sw_vers`；`vtool -show-build <macho>`（§2.1） |
| CPU 架构 | **arm64（仅）**，无 universal2/x86_64 | `scripts/build-freerdp.sh`（CMake 的 SDK/架构/部署目标选项）（`CMAKE_OSX_ARCHITECTURES=arm64`）；`docs/DESIGN-2026-11-08-app-packaging.md` §10 | 依赖与产物架构 | 必需 | `uname -m`；`lipo -archs` |
| Xcode Command Line Tools | 本机 Swift 6.4.2 / clang 21（版本未固定） | `AGENTS.md` §4.1 前置依赖 / §7 代码约定；本机 `xcode-select -p` = `/Library/Developer/CommandLineTools` | Swift 构建、C 编译 | 必需 | `swift --version`；`xcrun --sdk macosx --show-sdk-path` |
| Go | 下限 **1.27**；本机 1.27.3 | `go.mod` 的 `go` 指令（`go 1.27`，无 `toolchain` 指令） | Worker / probe / CLI 与 cgo | 必需 | `go version` |
| CMake | 下限 ≥3.15（推断）；项目约定 4.x；本机 4.4.5 | `scripts/build-freerdp.sh`（CMake 配置/构建/安装段）（用到 `cmake --build --parallel`、`cmake --install`）；`README.md`「系统要求与依赖」 | 构建 FreeRDP | 必需 | `cmake --version` |
| Homebrew OpenSSL 3 | 未固定；本机 3.5.9 | `scripts/build-freerdp.sh`（`OPENSSL_ROOT_DIR`）（`-DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3)`） | FreeRDP TLS/NLA 加密后端；证书生成脚本 | 必需 | `brew list --versions openssl@3`；`otool -L .deps/install/lib/libwinpr3.3.dylib` |
| Homebrew json-c | 未固定；本机 0.19 | 上游 WinPR CMake 自动发现（见 `.deps/build/CMakeCache.txt`）；打包后进入 `Contents/Frameworks` | WinPR 的 JSON 后端 | 构建宿主机实际需要（上游 `WITH_JSONC_REQUIRED` 默认 OFF，属可选） | `otool -L .deps/install/lib/libwinpr3.3.dylib`；`brew list --versions json-c` |
| pkg-config（Homebrew `pkgconf`） | 未固定；本机 3.0.10 | FreeRDP CMake 探测；`internal/worker/avc420_build.go`（`#cgo pkg-config:`）（`#cgo pkg-config:`） | 依赖探测 / AVC420 | 建议必需 | `pkg-config --version` |
| FreeRDP / WinPR | **3.32.2**（归档 SHA-256 固定） | `scripts/build-freerdp.sh`（`version`/`sha256`） | RDP 协议内核、NLA、图形/输入/剪贴板通道 | 必需 | 见 §4.7 |
| Python 3 | 下限 3.9（系统 `/usr/bin/python3` = 3.9.6）；构建/测试脚本仅标准库 | `Makefile` 各测试/打包目标的 `python3` 调用；`scripts/*.py` 全部 `#!/usr/bin/env python3` | 构建/测试/打包脚本 | 必需 | `python3 --version`；`ls requirements*.txt`（不存在） |
| Pillow（仅重生成图标） | 未固定（本机已安装；不是构建/运行依赖） | `scripts/generate-app-icon.py` | 合成 `AppIcon.icns`（白色线稿素材 `AppIcon-art.png` + 深色圆角底，§7.3） | **可选（开发）** | `python3 -c 'import PIL; print(PIL.__version__)'` |
| 许可证/合规文件 | 项目 **Apache-2.0**；第三方见文件 | 仓库根 `LICENSE`、`NOTICE`、`THIRD-PARTY-NOTICES.md` | 分发合规（随 DMG 复制到 `Resources/Licenses/`） | 分发必需 | `ls -l LICENSE NOTICE THIRD-PARTY-NOTICES.md`；`make test-app-bundle`（§8） |
| FFmpeg（含开发包） | 未固定；本机 ffmpeg 9.0.2_1、libavcodec 63.1.102 | `internal/worker/avc420_build.go`（`//go:build avc420`、`#cgo pkg-config:`）；`Makefile`（`build-avc420-worker` / `test-avc420-*` 目标） | AVC420 实验编码路径 | **可选** | `pkg-config --modversion libavcodec`（§7.1） |
| Windows App / mstsc | 未固定 | `README.md`（客户端连接步骤见「快速开始 A」） | 人工验收客户端（非构建依赖） | 可选 | 手工验证 |
| macOS 自带工具 | 随系统 | `scripts/build-freerdp.sh`（下载/校验段）（curl/shasum/tar）；`scripts/package-app-dmg.py`（otool/vtool/codesign/install_name_tool/hdiutil） | 下载/校验/打包 | 必需（系统自带） | `command -v curl shasum tar otool vtool codesign hdiutil` |

补充事实（均可核对）：

- SwiftPM 工具链版本 `5.9`（`native/macos/Package.swift`（`swift-tools-version`））；**无 SPM 依赖**（`Package.swift` 没有 `dependencies:` 段）。
- **无第三方 Go 依赖**：`go.mod` 只有 `module rdp-server` 与 `go 1.27`，仓库无 `go.sum`、无 `vendor/`（`go list -m all` 只输出 `rdp-server`）。
- **无 Python 第三方包**：仓库无 `requirements.txt` 等清单；除**可选的 Pillow**（仅重新生成图标，§7.3）外，所有脚本只用标准库。
- 系统 `/usr/bin/openssl` 是 **LibreSSL 3.3.6**，不是 OpenSSL 3；证书生成/校验脚本使用 Homebrew `openssl@3`：`scripts/dev-init.py`（`brew --prefix openssl@3`） 通过 `brew --prefix` 定位，`scripts/disp-diagnose.py`（`OPENSSL_CANDIDATES`/`find_openssl()`） 先试 `/opt/homebrew/opt/openssl@3` 再回退 `shutil.which("openssl")`；**仍硬编码** `/opt/homebrew/opt/openssl@3/bin/openssl` 的是 `scripts/test-protocol.py`（生成自签证书处） 与 `scripts/benchmark-fps.py`（`OPENSSL` 常量）（非 Apple Silicon Homebrew 前缀的机器需改这两处，见 §9.2）。
- 测试临时目录不再硬编码本机 TMPDIR：`scripts/test-protocol.py`、`scripts/test-agent-ipc-wire.py`、`scripts/test-worker-auto-lan.py` 与 `internal/agentipc/unix_frames_test.go` 均改为「优先 `/tmp`、回退平台 TMPDIR，并校验 Unix socket 路径 < 104 字节」。
- 仓库根提供 `LICENSE`（Apache License 2.0 全文）、`NOTICE` 与 `THIRD-PARTY-NOTICES.md`；本项目自身许可证为 **Apache-2.0**，随 DMG 分发规则见 §8。

## 2. 系统与宿主环境

### 2.1 最低 macOS 14.0（依据）

| 位置 | 声明 |
| --- | --- |
| `native/macos/Package.swift`（`platforms` 声明） | `platforms: [.macOS(.v14)]` —— SwiftPM 产物与嵌套 Agent 的部署目标 |
| `Makefile`（`MACOSX_DEPLOYMENT_TARGET`/`CGO_CFLAGS`/`CGO_LDFLAGS`） | `MACOSX_DEPLOYMENT_TARGET := 14.0` + `CGO_CFLAGS/CGO_LDFLAGS := -mmacosx-version-min=14.0`（Go+cgo helper） |
| `scripts/build-freerdp.sh`（CMake 的 SDK/架构/部署目标选项） | `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0`（FreeRDP/WinPR） |
| `scripts/package-app-dmg.py`（`MINIMUM_SYSTEM_VERSION`/`TARGET_MINOS`；`info_plist()` 写入 `LSMinimumSystemVersion`） | `MINIMUM_SYSTEM_VERSION = "14.0"`、`TARGET_MINOS = "14.0"` |

技术依据：Agent 使用 `SCScreenshotManager`（macOS 14.0 起可用，`native/macos/Sources/rdp-agent/main.swift`（`SCScreenshotManager.captureImage`）），因此运行下限不高于也不低于 14.0。源码中没有 `@available` 分支，因为部署目标本身已声明 14.0。

打包后必须审计（`scripts/package-app-dmg.py` 的 `normalize_minimum_versions()` 会用 `vtool` 把第三方 dylib 的 minos 归一化到 14.0 并重签）：

```sh
for f in dist/RDPServer.app/Contents/{MacOS/*,Helpers/rdp-worker,Helpers/rdpctl,Frameworks/*.dylib}; do
  printf '%s: ' "$f"; vtool -show-build "$f" | grep minos
done
# 期望全部为 minos 14.0
```

本机 2026-11-09 的 DMG 实测：7 个 dylib + 2 个 helper + 主可执行全部 `minos 14.0`；而宿主机 Homebrew 原始 bottle 是 `libssl.3/libcrypto.3 = minos 27.0`、`libjson-c.5 = minos 26.0` —— 这正说明归一化步骤**不可省略**：dyld 不接受 minos 高于当前系统的镜像，跳过它包会在 macOS 26 目标机上加载失败/启动失败。

### 2.2 架构：仅 arm64

- FreeRDP/WinPR 以 `-DCMAKE_OSX_ARCHITECTURES=arm64` 构建（`scripts/build-freerdp.sh`（CMake 的 SDK/架构/部署目标选项））。
- 打包脚本没有 `lipo` 合并步骤，`Contents/Frameworks` 直接复制单架构 dylib（`scripts/package-app-dmg.py`（`bundle_dylibs()`））。
- 硬件/架构边界见 `docs/DESIGN-2026-11-08-app-packaging.md` §10「仅 arm64（Apple Silicon）；未做 universal2 / x86_64」。
- 验证：`grep CMAKE_OSX_ARCHITECTURES .deps/build/CMakeCache.txt`、`lipo -archs dist/RDPServer.app/Contents/MacOS/RDPServer`。

### 2.3 Xcode Command Line Tools（不需要完整 Xcode）

- 构建只用 `swift build` / `swiftc` / `clang` / `make`，这些由 CLT 提供；本机 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，仓库的构建与打包流程在此环境下成立。
- **不要求完整 Xcode 的原因**：菜单栏 App 的 SwiftUI 代码刻意不使用需要宏插件的 API（`@State`/`@FocusState`/`#Preview`/`@AppStorage` 等），只用 `ObservableObject`/`@Published`/`@Binding` 与 AppKit，所以 CLT-only 工具链可编译（约束见 `AGENTS.md` §7 代码约定）。打包脚本还会删除 Swift 产物里指向 `/Library/Developer/...` 的 rpath，使成品在没有 CLT 的目标机上也能运行（`scripts/package-app-dmg.py`（`strip_unneeded_rpaths()`/`strip_dev_rpaths()`））。
- 若机器上装了完整 Xcode，注意 `xcrun --sdk macosx --show-sdk-path` 会返回 Xcode 的 SDK；SDK 版本会影响 FreeRDP 的 availability 探测（§4.3），跨机器构建时用 `MACOSX_SDK_ROOT` 显式指定。

### 2.4 运行期环境（非构建依赖）

- 运行时需要 macOS 14+、arm64；Agent 需要**屏幕录制**与**辅助功能** TCC 授权，文件剪贴板读取受保护目录时需要**完全磁盘访问**；TCC 身份是嵌套的 `RDPAgent.app`（bundle id `com.rdp-server.agent`），不是菜单栏 App。详见 `docs/DESIGN-2026-11-08-app-packaging.md` 与 `docs/STATUS-2026-11-08.md`。
- 产物为 ad-hoc 签名、未公证（`scripts/package-app-dmg.py`（`sign_bundle()`））；干净机器上的 Gatekeeper/TCC 首启流程**未验证**（见 `docs/STATUS-2026-11-08.md`「已知限制」）。
- 不安装系统服务/驱动，不修改 TCC 数据库；Worker 默认只监听 `127.0.0.1`。

## 3. 语言与工具链版本

| 组件 | 声明/下限 | 本机实测 | 说明 |
| --- | --- | --- | --- |
| Go | `go 1.27`（`go.mod` 的 `go` 指令） | 1.27.3 | 无第三方模块；无 `toolchain` 指令 |
| Swift / SwiftPM | tools `5.9`（`native/macos/Package.swift`（`swift-tools-version`）），部署目标 macOS 14 | Swift 6.4.2（CLT） | 无 SPM 依赖 |
| CMake | 脚本要求 ≥3.15（推断：`cmake --install` 自 3.15 起）；上游 FreeRDP 3.32.2 自身要求 ≥3.13（`.deps/freerdp-3.32.2/CMakeLists.txt:21`） | 4.4.5 | 项目文档写作「CMake 4」（`README.md`） |
| Python | 3.9+ | `/usr/bin/python3` = 3.9.6 | 仅标准库；29 个脚本均为 `python3` shebang |
| OpenSSL | Homebrew `openssl@3`（未固定具体版本） | 3.5.9 | 构建时链接；运行期由 DMG 自带副本提供 |
| json-c | Homebrew（未固定） | 0.19 | 上游可选 JSON 后端，当前包实际链接 |

## 4. 第三方源码依赖：FreeRDP / WinPR 3.32.2

### 4.1 来源与完整性校验

```sh
# scripts/build-freerdp.sh 的 version/sha256/下载段（摘要）
version=3.32.2
sha256=e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c
# 下载：https://github.com/FreeRDP/FreeRDP/releases/download/3.32.2/freerdp-3.32.2.tar.gz
# 归档已存在则复用；每次都用 shasum -a 256 校验，不匹配即 exit 1
```

- 归档大小约 11 MB（本机 `.deps/downloads/freerdp-3.32.2.tar.gz` = 11,288,855 B）；解压根目录 `freerdp-3.32.2/`。
- 上游归档只有**顶层 `LICENSE`（Apache-2.0 全文）**，**没有 archive 级 `NOTICE`**；归档内唯一的 `NOTICE` 是 AOSP 派生的 `winpr/libwinpr/sysinfo/cpufeatures/NOTICE`（仅 Android 构建启用，macOS 不编译该组件）。归属与分发处理见 §8 与 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)。
- 目录布局（全部 gitignored，见 `.gitignore`）：

| 路径 | 内容 |
| --- | --- |
| `.deps/downloads/freerdp-3.32.2.tar.gz` | 归档缓存（校验通过才继续） |
| `.deps/freerdp-3.32.2/` | 解压后的上游源码 |
| `.deps/build/` | CMake 构建树（默认；可用 `FREERDP_BUILD_DIR` 覆盖） |
| `.deps/install/` | 安装前缀（cgo 链接目标；可用 `FREERDP_INSTALL_PREFIX` 覆盖） |

- 环境变量覆盖点：`FREERDP_BUILD_DIR`（:8）、`FREERDP_INSTALL_PREFIX`（:9）、`OPENSSL_ROOT_DIR`（:10）、`MACOSX_SDK_ROOT`（:25）、`BUILD_JOBS`（:37，默认 6）。`MACOSX_SDK_ROOT` + 独立 build/install 目录是同时保留多套 SDK 变体（历史上 `.deps/build-macos26`/`install-macos26` 等）的机制。

### 4.2 CMake 关键选项（`scripts/build-freerdp.sh`（CMake 配置段））

| 选项 | 值 | 作用 / 原因 |
| --- | --- | --- |
| `CMAKE_BUILD_TYPE` | `RelWithDebInfo` | 优化构建，保留符号 |
| `CMAKE_INSTALL_PREFIX` | `.deps/install`（可覆盖） | cgo 的 `-I/-L` 前缀 |
| `CMAKE_OSX_SYSROOT` | `${MACOSX_SDK_ROOT:-$(xcrun --sdk macosx --show-sdk-path)}` | 显式选 SDK，避免 availability 探测随宿主漂移 |
| `CMAKE_OSX_DEPLOYMENT_TARGET` | `14.0` | 产物可在 macOS 14+ 运行 |
| `CMAKE_OSX_ARCHITECTURES` | `arm64` | 仅 Apple Silicon |
| `WINPR_HAVE_PIPE2` | `OFF` | 强制可移植 `pipe()+fcntl(FD_CLOEXEC)` 路径（§4.3） |
| `OPENSSL_ROOT_DIR` | `$(brew --prefix openssl@3)` | 固定加密后端来源 |
| `WITH_OPUS` | `OFF` | 宿主 opus 头文件会让 CMake 探测失败并中断干净构建（`scripts/test-freerdp-sdk-selection.py` 有断言） |
| `WITH_SERVER` | `ON` | 本项目是 RDP 服务端 |
| `WITH_CLIENT` / `WITH_SAMPLE` | `OFF` | 不需要客户端程序与示例 |
| `WITH_CLIENT_COMMON` | `ON` | 生成 `libfreerdp-client3`（`rdp-probe` 与 cgo 链接需要，见 `internal/worker/worker.go`（`#cgo LDFLAGS` 的 rpath）） |
| `WITH_X11` / `WITH_PLATFORM_SERVER` | `OFF` | macOS 无 X11 |
| `WITH_CHANNELS` | `ON` | cliprdr / rdpgfx / disp 等虚拟通道 |
| `WITH_PROXY` / `CHANNEL_URBDRC` / `WITH_SHADOW` | `OFF` | 不需要 |
| `WITH_FFMPEG` / `WITH_SWSCALE` / `WITH_OPENH264` | `OFF` | 默认产品不含视频编码；AVC420 走独立的 FFmpeg cgo 路径（§7.1） |
| `WITH_WEBVIEW` / `WITH_CUPS` / `WITH_PCSC` / `WITH_MANPAGES` | `OFF` | 无关组件 |
| `WITH_AAD` / `WITH_KRB5` / `WITH_PKCS11` | `OFF` | 认证面收窄，只保留 HYBRID NLA |
| `BUILD_TESTING` | `OFF` | 不构建上游测试 |
| `WITH_INTERNAL_MD4` / `WITH_INTERNAL_RC4` | `ON` | NT 哈希/NLA 不依赖目标机的 OpenSSL legacy provider（§4.4） |

### 4.3 为什么显式选 SDK 并关闭 `WINPR_HAVE_PIPE2`

根因（`docs/VERIFICATION-2026-11-09-macos26-sdk-build.md` §2-3，`scripts/test-freerdp-sdk-selection.py` 文件头注释）：

- WinPR 在 `WINPR_HAVE_PIPE2` 打开时调用 `pipe2()`；用 macOS 27 SDK 构建会产生对 `_pipe2` 的**弱导入**，而 macOS 26 的 libSystem **不导出**该符号 → 弱导入槽为 NULL，`winpr_event_init()` 调用即跳转到 0（Worker 启动崩溃）。
- `minos=14.0` 只声明「可运行在 14+」，不能让目标机凭空拥有新 API。

两个构建设置在不改 FreeRDP 源码的前提下消除该符号：

1. `-DCMAKE_OSX_SYSROOT=<显式 SDK>`：CMake 的 availability 探测（部署目标 macOS 14）会拒绝 `pipe2`，自动把 `WINPR_HAVE_PIPE2` 置空；
2. `-DWINPR_HAVE_PIPE2=OFF`：即使未来 SDK 探测行为变化，也强制可移植路径。

验证方式：

```sh
make test-freerdp-sdk-selection            # 守护脚本内容（SDK 选择 + pipe2 OFF + 14.0 + 隔离目录）
make test-freerdp-no-pipe2                 # 守护构建配置与上游调用点
RDP_TEST_WINPR_DYLIB=.deps/install/lib/libwinpr3.3.dylib \
  python3 scripts/test-freerdp-no-pipe2.py   # 额外断言产物无 _pipe2 未定义导入
nm -u .deps/install/lib/libwinpr3.3.dylib | grep -i pipe2   # 应无输出
```

推荐做法：目标机是 macOS 26 时优先用 macOS 26 SDK 构建依赖（`MACOSX_SDK_ROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`），再 `make app-dmg`；不设置 `MACOSX_SDK_ROOT` 时用宿主默认 SDK，因为 `-DWINPR_HAVE_PIPE2=OFF` 仍在，产物同样不含 `_pipe2`（`docs/VERIFICATION-2026-11-09-macos26-sdk-build.md` §4）。

### 4.4 内置 MD4/RC4（OpenSSL 3 legacy provider 问题）

- 现象：NT 哈希（NTLM）需要 MD4；OpenSSL 3 把 MD4/RC4 放进 key 为 `legacy` 的 provider **模块**，模块路径被编译进构建机的 Homebrew OpenSSL，目标 Mac 没装 Homebrew 时模块不存在 → Worker/`rdpctl` 无法计算 NT 哈希，NLA 失败。
- 修复：`-DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON`（`scripts/build-freerdp.sh`（`WITH_INTERNAL_MD4/RC4`）），WinPR 用内置实现，不再依赖 legacy provider 模块。
- 验证：`OPENSSL_MODULES=/tmp/nonexistent OPENSSL_CONF=/dev/null` 下 `rdpctl hash-stdin` + `make test-protocol` 全绿。日志里的 legacy provider 警告无害（`docs/STATUS-2026-11-08.md`、`AGENTS.md` §4.1）。
- 注意：改这两个选项后必须重跑 `make deps` 再重新打包，否则 DMG 里的 dylib 仍是旧配置。

### 4.5 安装前缀与 cgo 链接（含绝对 rpath 陷阱）

`internal/worker/worker.go`（`#cgo CFLAGS/LDFLAGS`） 写死链接参数（`${SRCDIR}` 由 cgo 展开为**绝对路径**）：

```c
#cgo CFLAGS:  -I${SRCDIR}/../../.deps/install/include/freerdp3 -I${SRCDIR}/../../.deps/install/include/winpr3
#cgo LDFLAGS: -L${SRCDIR}/../../.deps/install/lib -lfreerdp-server3 -lfreerdp-client3 -lfreerdp3 -lwinpr3 \
             -Wl,-rpath,${SRCDIR}/../../.deps/install/lib
```

后果（本机实测）：`bin/rdp-worker` 的 `LC_RPATH` 是
`/Users/<checkout>/internal/worker/../../.deps/install/lib`。

- **移动/复制/重命名仓库后必须重跑 `make build`**（否则运行期 dyld 找不到 FreeRDP）；删除 `.deps` 同理。
- DMG 打包会重写这部分：`install_name_tool` 把依赖改成 `@rpath/<basename>`、删除仓库/.deps rpath、加 `@executable_path/../Frameworks`（`scripts/package-app-dmg.py`（`rewrite_executable()`/`rewrite_dylib()`）），所以**成品 app 可搬运**，而 `bin/` 下的开发产物不可搬运。
- 如果要在不覆盖 `bin/` 的前提下验证，请按 `AGENTS.md` §4.3 构建到 `/tmp` 并用 `RDP_TEST_*_BINARY` 指定；`make build`/`make test-protocol` 会覆盖部署产物。

### 4.6 产物与外部依赖

`.deps/install/lib` 内容（本机实测）：

- `libfreerdp3.3.32.2.dylib`、`libfreerdp-server3.3.32.2.dylib`、`libfreerdp-client3.3.32.2.dylib`、`libwinpr3.3.32.2.dylib`、`libwinpr-tools3.3.32.2.dylib`，以及 soname 符号链接（如 `libfreerdp3.3.dylib` → `libfreerdp3.3.32.2.dylib`）；
- pkg-config 文件（`freerdp3.pc` 等）记录 `Version: 3.32.2`，可用于核对版本；
- 非系统依赖（`otool -L`）：`/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib`、`libcrypto.3.dylib`（经 WinPR 还有 `/opt/homebrew/opt/json-c/lib/libjson-c.5.dylib`）；其余为 `libz`、`libSystem`、Carbon/CoreFoundation/IOKit/Foundation/objc 等系统库。**Homebrew 绝对路径会在打包时被重定位**。

DMG 内实际分发的 7 个 dylib（本机 `dist/RDPServer.app/Contents/Frameworks` 实测，与 `docs/DESIGN-2026-11-08-app-packaging.md` §3「Bundle 布局契约」一致）：

`libfreerdp-server3.3.dylib`、`libfreerdp-client3.3.dylib`、`libfreerdp3.3.dylib`、`libwinpr3.3.dylib`、`libssl.3.dylib`、`libcrypto.3.dylib`、`libjson-c.5.dylib`。

### 4.7 验证命令汇总

```sh
grep -h '^Version' .deps/install/lib/pkgconfig/*.pc              # 3.32.2
grep -E 'WINPR_HAVE_PIPE2|CMAKE_OSX_DEPLOYMENT_TARGET|CMAKE_OSX_ARCHITECTURES|OPENSSL_ROOT_DIR' \
  .deps/build/CMakeCache.txt
nm -u .deps/install/lib/libwinpr3.3.dylib | grep -i pipe2        # 应无输出
vtool -show-build .deps/install/lib/libwinpr3.3.dylib | grep minos   # 期望 14.0
otool -L .deps/install/lib/libwinpr3.3.dylib                     # 期望 openssl@3 / json-c 引用
make test-freerdp-sdk-selection && make test-freerdp-no-pipe2
```

### 4.8 升级 FreeRDP/WinPR 的步骤

1. 修改 `scripts/build-freerdp.sh` 的 `version` 与 `sha256`；新归档的 SHA 用 `shasum -a 256 .deps/downloads/freerdp-<ver>.tar.gz` 得到（先让它下载一次或手工放置）。
2. 逐项核对 CMake 选项在新版本是否仍存在（尤其 `WINPR_HAVE_PIPE2`、`WITH_INTERNAL_MD4/RC4`、`WITH_CLIENT_COMMON`）；上游若改了探测/选项名，同步 `scripts/build-freerdp.sh` 与 `scripts/test-freerdp-sdk-selection.py`。
3. 用干净构建目录重建：`rm -rf .deps/build`（或设新的 `FREERDP_BUILD_DIR`）→ `make deps`。
4. 跑 §4.7 的验证 + `make check` + `make test-protocol`（需 `bin/`，注意部署纪律）；真机客户端行为仍需人工验收。
5. `make app-dmg` → `make test-app-bundle`（校验 dylib 重定位、helpers 加载、可搬运、自检）。
6. 更新本文 §1/§4 的版本、SHA、选项；历史 `docs/` 记录按项目约定保留、不改写。

## 5. 构建命令与产物

### 5.1 make 目标

| 目标 | 作用 | 前置 / 风险 |
| --- | --- | --- |
| `make deps` | 下载+校验+CMake 构建 FreeRDP 3.32.2 → `.deps/install` | **唯一联网步骤**；每次都会重跑 configure/build/install（增量）；不要并发跑 |
| `make build` | `go build -o bin/ ./cmd/...` | **覆盖 `bin/`**（线上部署产物）；需 `.deps/install` |
| `make build-avc420-worker` | `go build -tags avc420 -o bin/rdp-worker-avc420` | 需 FFmpeg 开发包；覆盖 `bin/` 中该文件 |
| `make test` | `go test -race ./...` | 需 `.deps/install`；可能命中缓存 |
| `make check` | `test` + `test-gfx-session` + `test-avc-encoder` + `go vet ./...` | 项目默认必过集合 |
| `make test-protocol` | 依赖 `build`，跑 loopback 协议 E2E | **会覆盖 `bin/`**；需本机 TCP 监听；约 90–100 s |
| `make test-gfx-session` | C 策略 harness（用 `cc` + `.deps/install` 头文件） | 需 `.deps/install` |
| `make test-avc-encoder` | AVC 编码器 harness | FFmpeg 开发包缺失时相关用例 skip；`--require-ffmpeg` 改为失败 |
| `make test-freerdp-sdk-selection` | 守护 SDK 选择与 pipe2 选项 | 纯 Python，不编译 |
| `make test-freerdp-no-pipe2` | 守护构建配置/产物无 `_pipe2` | 可选用 `RDP_TEST_WINPR_DYLIB` 检查产物 |
| `make agent-build` | `swift build -c release` + 复制 → `bin/rdp-agent` | 覆盖 `bin/rdp-agent` |
| `make agent-app` | 依赖 `agent-build`，再 `scripts/package-agent-app.py` → ad-hoc 签名 `bin/RDPAgent.app` | TCC 身份产物 |
| `make agent-check` | 用 `swiftc` 编译手写文件清单（24 个核心源文件 + 6 个测试文件）并运行 | 新增 Swift 文件必须同步该清单（`Makefile` 的 `agent-check` 目标） |
| `make app-build` | `swift build -c release`（含菜单栏 App） | 不写 `bin/` |
| `make app-dmg` | `dist/build/{rdp-worker,rdpctl}`、`dist/RDPServer.app/`（含 `Contents/Resources/Licenses/`）、`dist/RDPServer-0.2.4.dmg`、`dist/dmg-staging/` | 打包中间产物也在 `dist/` |
| `make test-app` | `scripts/test-app-core.py`（App 核心无头契约） | 隔离临时目录/随机端口，不碰 `.runtime` |
| `make test-app-bundle` | 只读挂载 DMG（`hdiutil attach -readonly`），跑 **17 个命名检查**（`checker.run(...)`，含 `license files` 与 `live data dir untouched`）；另有 1 个 shared 信息项（`shared .runtime unchanged`，OK/WARN，不计入 check 总数）。`--skip-service-check` 时 summary 为 **16 passed + 1 skipped**（总数仍 17） | DMG 缺失时会自动调用打包脚本（`--no-build` 则直接失败） |
| `make test-virtual-display` | 虚拟显示器集成 harness（6 例） | **会短暂切换真实显示排列**，有活动用户会话时勿跑 |
| `make test-agent-ipc-wire` | 真实 Unix socket 的 IPC 线格式测试 | 需 Swift 工具链 |
| `make test-agent-launchd` | LaunchAgent plist/bundle 单元测试 | 无 |
| `make test-windows-app-smoke` | Windows App 日志判定器单测（不启动 App） | 无 |
| `make test-performance-baseline` | 性能日志统计单测 | 无 |
| `make test-worker-auto-lan` | 依赖 `build`，隔离验证 `address:auto`：正常停止、父进程死亡后受管 Worker 退出、子进程重启重建 `agent.sock`（3 例） | 需私有 LAN 地址；无 LAN 失败不代表回归 |

`.PHONY` 与目标定义见 `Makefile`；这里省略了 AVC420 的 `make test-avc420-build` / `make test-avc420-gfx-probe`（见 §7.1）。

> **计数口径**：`make test-app-bundle` 的 17 个检查全部来自脚本里的 `checker.run(...)`；`warn_runtime_noise()` 额外输出 1 个 shared 信息项（`shared .runtime unchanged`，OK/WARN），它单独打印、不计入 summary 的 check 数。因此默认干净跑为 `17 passed, 0 failed, 0 skipped … 17 check(s)`，加上该信息项约 18 行结果；`--skip-service-check` 为 `16 passed, 0 failed, 1 skipped … 17 check(s)`。**旧 DMG（在许可证复制逻辑之前构建）的 `license files` 必然失败，属预期——重新 `make app-dmg` 后再验。**
>
> 部署纪律：在本机可能正有 RDP 会话时，不要用 `make build`/`make test-protocol` 覆盖 `bin/`。验证新代码请构建到 `/tmp` 并用 `RDP_TEST_WORKER_BINARY`/`RDP_TEST_PROBE_BINARY` 跑测试（`AGENTS.md` §4.3）。

### 5.2 首次构建顺序

```sh
brew install cmake pkgconf openssl@3 json-c   # 一次性（联网；Apple Silicon 前缀 /opt/homebrew）；Go 用 Homebrew 或官方安装包
make deps            # 唯一联网构建步骤；分钟级
make build           # bin/rdp-worker、bin/rdp-probe、bin/rdpctl
make check           # Go race + gfx/avc 策略 + go vet
make agent-build     # bin/rdp-agent（Swift release）
make agent-check     # Swift 纯逻辑测试
make agent-app       # bin/RDPAgent.app（TCC 身份）
make app-dmg         # 可选：dist/RDPServer.app + dist/RDPServer-0.2.4.dmg
make test-app-bundle # 可选：发布前 DMG/bundle 校验
```

顺序约束只有两条：**`make deps` 必须先于任何 cgo 构建**（`build`/`test`/`check`/`test-protocol`/`app-dmg` 编译 Go 时都需要 `.deps/install`）；**`make test-app-bundle` 需要 DMG**——它默认会自行调用打包脚本生成缺失的 DMG（`--no-build` 时才直接失败）。`make app-dmg` 自己会构建 Go helper 到 `dist/build/` 并调用 SwiftPM，但要求 `.deps/install` 已存在。

### 5.3 产物路径

| 目标 | 产物 | 说明 |
| --- | --- | --- |
| `make deps` | `.deps/downloads/`、`.deps/freerdp-3.32.2/`、`.deps/build/`、`.deps/install/` | 全部 gitignored |
| `make build` | `bin/rdp-worker`、`bin/rdp-probe`、`bin/rdpctl` | `cmd/` 下三个入口 |
| `make build-avc420-worker` | `bin/rdp-worker-avc420` | 需 FFmpeg |
| `make agent-build` | `native/macos/.build/release/rdp-agent` → `bin/rdp-agent` | |
| `make agent-app` | `bin/RDPAgent.app` | TCC 身份 `com.rdp-server.agent` |
| `make app-build` | `native/macos/.build/release/{RDPServer,rdp-agent}` | 不写 `bin/` |
| `make app-dmg` | `dist/build/{rdp-worker,rdpctl}`、`dist/RDPServer.app/`、`dist/RDPServer-0.2.4.dmg`、`dist/dmg-staging/` | 打包中间产物也在 `dist/` |
| `make test-*` | 无持久产物 | 临时目录/随机端口，结束后清理 |

### 5.4 联网 / 离线边界

| 操作 | 是否联网 | 说明 |
| --- | --- | --- |
| `brew install/upgrade ...` | 是 | 前置，手工执行 |
| `make deps` | **是（唯一构建步骤）** | `curl --connect-timeout 20 --max-time 300 --retry 2` 从 GitHub Release 下载；归档已存在则跳过下载（仍会跑 CMake） |
| `make build`/`check`/`test-*`/`agent-*`/`app-*` | 否 | 只读本地 `.deps`、Homebrew 前缀与仓库文件 |
| `make test-protocol` | 否（但需本机 TCP listen 权限） | 只连 loopback；沙箱拒绝监听时换允许 loopback 的环境，不要改测试断言 |

### 5.5 缓存与忽略规则

- Go 构建缓存：`.cache/go-build`（`Makefile`（`GOCACHE`） 导出 `GOCACHE`；直接跑 `go test` 时用默认缓存，无妨）。
- Swift 构建缓存：`native/macos/.build`。仓库根的 `./.build/` 存根（`CACHEDIR.TAG`/`.buildSystem_debug`）已移除且不再被跟踪；真正的 Swift 输出只在 `native/macos/.build`，两者不要混用。
- CMake 构建树：`.deps/build`。
- 忽略规则见 `.gitignore`：构建产物与私有状态（`.deps/`、`.cache/`、`.runtime/`、`bin/`、`native/macos/.build/`、`dist/`、`.worktrees/`、`*.dSYM/`），以及 2026-11-09 增补的卫生条目（`.DS_Store`、`*.log`、`*.dmg`、`*.dmg.zip`、`*.pem`、`*.key`、`*.sock`、`.env`、`.env.*`、`__pycache__/`、`*.pyc`、`.idea/`、`.vscode/`、`.swiftpm/`、`*.xcuserstate`、`*.local.rdp`、`.team/`）。`docs/` 全部入库。

## 6. 版本号管理（当前 0.2.4）

### 6.1 0.2.4 出现在哪里

| 位置 | 内容 | 说明 |
| --- | --- | --- |
| `native/macos/Sources/RDPServerCore/Version.swift`（`RDPServerCoreVersion.value`） | `public static let value = "0.2.4"` | 唯一源码版本常量；`RDPServer --version`（`RDPServerCLI.swift` 的 `--version` 分支）与 `--status` JSON（`StatusReport.swift` 的 `appVersion`）都读它 |
| `scripts/package-app-dmg.py`（`VERSION`） | `VERSION = "0.2.4"` | 决定 `Info.plist` 的 `CFBundleShortVersionString`（`info_plist()`）与 DMG 文件名（`DMG_PATH`） |
| `scripts/package-app-dmg.py`（`BUILD_NUMBER`） | `BUILD_NUMBER = "1"` | `CFBundleVersion`，与产品版本号独立 |
| `scripts/test-app-bundle.py`（`DMG_PATH`/`EXPECTED_VERSION`） | `DMG_PATH = ...RDPServer-0.2.4.dmg`、`EXPECTED_VERSION = "0.2.4"` | 打包校验的期望值；不同步会直接 fail |
| `scripts/test-app-core.py`（`--version` 断言） | 断言 `--version` 输出含 `"0.2.4"` | App 核心无头测试 |
| `THIRD-PARTY-NOTICES.md` 顶部「适用产物」 | 「适用产物：发布用 DMG / App（`make app-dmg` 生成 `dist/RDPServer-0.2.4.dmg` 与 `dist/RDPServer.app`）」 | 发布产物引用；改产品版本号时同步（组件版本/许可证表格不随产品版本变） |
| `scripts/package-agent-app.py`（`DEFAULT_VERSION`） | `DEFAULT_VERSION = "0.1.0"` | **独立** `make agent-app`（`bin/RDPAgent.app`）的默认版本；`make app-dmg` 调用时会显式传 `version=VERSION`（`assemble_app()`），故 DMG 内嵌套 Agent 是 0.2.4、而独立 app 是 0.1.0。这是两个不同的发布物，改版本时注意区分 |
| `README.md`、`AGENTS.md`、`docs/*` | DMG 文件名/版本描述 | 对外文档需同步；历史 `docs/` 记录是历史证据，按项目约定不改写 |

### 6.2 升级版本号的清单

1. `native/macos/Sources/RDPServerCore/Version.swift`（`RDPServerCoreVersion.value`）
2. `scripts/package-app-dmg.py` 的 `VERSION`（DMG 文件名与 Info.plist 由此派生）
3. `scripts/test-app-bundle.py` 的 `DMG_PATH` 与 `EXPECTED_VERSION`
4. `scripts/test-app-core.py` 的 `--version` 断言字符串
5. `THIRD-PARTY-NOTICES.md` 顶部「适用产物」的 DMG/App 名
6. `README.md` / `AGENTS.md` / 相关 `docs/` 中的 DMG 文件名与版本描述
7. 可选：`scripts/package-agent-app.py` 的 `DEFAULT_VERSION`（若希望独立 `bin/RDPAgent.app` 也跟随产品版本；不跟随也没问题，但要在发布说明里说清）
8. 重建与验证：

```sh
make app-build && make app-dmg && make test-app-bundle
dist/RDPServer.app/Contents/MacOS/RDPServer --version        # 期望新版本
plutil -p dist/RDPServer.app/Contents/Info.plist | grep -E 'ShortVersion|BundleVersion|MinimumSystem'
```

9. 记录新 DMG 的 SHA-256（`shasum -a 256 dist/RDPServer-<ver>.dmg`）。当前没有自动化发布流程；建议每个发布打 `vX.Y.Z` tag，并把 DMG 的 SHA-256 写进发布说明。
10. 更新本文 §1/§6/§8.1 中的产物名。

## 7. 可选依赖

### 7.1 FFmpeg / AVC420（实验性，默认产品不含）

- 开关：Go build tag `avc420`（`internal/worker/avc420_build.go`（`//go:build avc420`））；cgo 通过 pkg-config 找 `libavcodec libavutil libswscale`（`:7`）；C 实现 `internal/worker/avc_encoder.c`（包含 `libavcodec/avcodec.h`、`libavcodec/bsf.h`）。
- 相关目标（`Makefile`）：
  - `make build-avc420-worker` → `bin/rdp-worker-avc420`（:18-20）；
  - `make test-avc420-build` → 带 tag 的 Go 测试（:55-56）；
  - `make test-avc420-gfx-probe` → 需要 `bin/rdp-probe`、`RDP_TEST_GFX=1 RDP_ENABLE_AVC420=1` 和 `DYLD_LIBRARY_PATH=.deps/install-h264/lib`（:58-59）。
- 版本未固定：本机 Homebrew `ffmpeg 9.0.2_1`、pkg-config `libavcodec 63.1.102` / `libavutil 61.1.102` / `libswscale 10.1.102`。**不要**在文档/脚本里假设某个 FFmpeg 大版本。
- 无 FFmpeg 开发包时：`make test-avc-encoder` 的相关用例 skip（`scripts/test-avc-encoder.py` 的 `--require-ffmpeg` 可改为失败）；`make check` 不会因此失败。
- 状态：实验性、未部署（`docs/STATUS-2026-11-08.md`「H.264/AVC420（GFX）」）；默认 `bin/rdp-worker` 不含该能力，运行期还需 `RDP_ENABLE_AVC420=1` 且编码器初始化成功。

### 7.2 `.deps/install-h264`（手工构建，不可复现）

- 这是**另一份手工构建**的 FreeRDP 安装前缀（带 FFmpeg/硬件加速选项），仓库里**没有生成脚本**；只有 `make test-avc420-gfx-probe` 通过 `DYLD_LIBRARY_PATH` 使用（`Makefile`（`test-avc420-gfx-probe` 目标））。
- 不可复现：无脚本、无版本记录、无校验；新机器上该目标失败属预期。
- 不要用它替换 `.deps/install`（ABI/选项不匹配，会污染正常构建）。
- 若确实要维护 AVC420 实验环境，建议后续补一个 `scripts/build-freerdp-h264.sh` 并把版本/选项写进本文；当前状态标「未验证」。

### 7.3 图标资源与 Pillow（仅重生成图标时需要）

- 应用图标 `native/macos/Resources/AppIcon.icns` 由**白色线稿寻呼机素材** `native/macos/Resources/AppIcon-art.png`（透明底、白色描边）合成：`scripts/generate-app-icon.py` 裁掉素材透明边距，铺到深色圆角底（渐变 + 细高光 + 发丝描边 + 柔和投影）上，再由 macOS `iconutil` 打包；不含 Apple Color Emoji 位图（旧 Emoji 图标已移除）。
- Pillow 是**环境/开发依赖，不是构建或运行依赖**：`make app-dmg` 只复制现成的 `.icns`（`scripts/package-app-dmg.py`：`assemble_app()` 复制 `APP_ICON_SOURCE`，`info_plist()` 写入 `CFBundleIconFile = AppIcon`），不执行图标脚本；仓库也没有 requirements 文件。缺 Pillow 时脚本会给出明确错误并退出。
- 重新生成（会覆盖被跟踪的 `.icns`）：`python3 scripts/generate-app-icon.py`；`--verify-only` 只校验；`--preview` / `--iconset` 输出到临时路径；`--art PATH` 可换素材。渲染确定性由 4x 绘制 + LANCZOS 保证（同一 Pillow/iconutil 版本）。
- 菜单栏状态项不再是 emoji：`native/macos/Sources/RDPServer/MenuBarIcon.swift` 用 NSBezierPath 绘制寻呼机模板图（`isTemplate = true`，1x/2x 位图），由系统按菜单栏外观着黑白，不随包分发任何位图资源；它与 App 图标（`.icns`）是两件事。

## 8. 第三方许可证与合规

### 8.1 组件清单

| 组件 | 版本 | 许可证 | 许可证文本位置 | 分发形态 |
| --- | --- | --- | --- | --- |
| **本项目（rdp-server）** | 0.2.4 | **Apache-2.0** | 仓库根 `LICENSE`（Apache License 2.0 全文）与 `NOTICE` | 源码；DMG 内 `Contents/Resources/Licenses/{LICENSE,NOTICE,THIRD-PARTY-NOTICES.md}` |
| FreeRDP（含 WinPR） | 3.32.2 | **Apache-2.0** | 上游归档根 `LICENSE`（与仓库 `LICENSE` 同为 Apache-2.0 全文）；归档**无 archive 级 NOTICE**；唯一 NOTICE 是 AOSP cpufeatures（Android-only，macOS 不编译，见 §8.5） | DMG 内 4 个 dylib（freerdp3/server/client、winpr3） |
| OpenSSL | 3.5.9（Homebrew，仓库未固定版本） | **Apache-2.0** | `$(brew --prefix openssl@3)/LICENSE.txt`；仓库 `LICENSE` 提供同一许可证全文 | DMG 内 `libssl.3`、`libcrypto.3` |
| json-c | 0.19（Homebrew，未固定；soname `libjson-c.5`） | **MIT** | `$(brew --prefix json-c)/COPYING`；MIT 全文与版权行见 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) §3.2 | DMG 内 `libjson-c.5` |
| Go 运行时 | 1.27.3（`go.mod` 要求 `go 1.27`） | **BSD-3-Clause** | Go 发行版 `LICENSE`；声明全文见 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) §3.3 | **静态链接**进 `rdp-worker` / `rdpctl`，无独立文件 |
| Apple 系统库/框架、Swift 运行库、zlib | 随 macOS | Apple 系统许可 | 系统内 | **不随包分发**（打包脚本按 `SYSTEM_PREFIXES` 跳过，`scripts/package-app-dmg.py`（`SYSTEM_PREFIXES`）） |
| 构建树中存在但不分发的组件 | — | — | — | `libwinpr-tools3.3.dylib`（未链接、未复制到 Frameworks）；FFmpeg/OpenH264/opus/CUPS/PCSC/KRB5/PKCS11/AAD 等构建选项均为 `OFF` |

逐组件的来源、版本核实、义务与许可证全文见 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)：§3.1 Apache-2.0、§3.2 MIT、§3.3 BSD-3-Clause、§3.4 FreeRDP 上游 AOSP NOTICE。`native/freerdp/README.md` 的 FreeRDP 许可证说明段已同步更正为「归档只有顶层 `LICENSE`、没有 archive 级 `NOTICE`；唯一 `NOTICE` 是 `winpr/libwinpr/sysinfo/cpufeatures/NOTICE`，仅 Android 构建启用」。

### 8.2 DMG 分发与动态链接义务

- 本包以**动态链接**分发 7 个第三方 dylib（`@rpath` 重定位；重写实现见 `scripts/package-app-dmg.py`（`rewrite_executable()`/`rewrite_dylib()`，由 `relocate_dylibs()` 调用）），不静态链入；Go 运行时是唯一的静态链接第三方代码。
- **Apache-2.0（本项目、FreeRDP、OpenSSL）**：分发时必须 (a) 提供许可证副本；(b) 保留版权、专利、商标与归属声明；(c) 若上游分发 `NOTICE`，随分发物包含其内容（本项目自身 `NOTICE` 已随包）；(d) 若修改文件则标注修改——本项目**未改 FreeRDP 源码**（`scripts/build-freerdp.sh` 无 patch/sed，只改 CMake 选项与固定归档 SHA），因此不涉及修改标注，但发布说明仍应写明构建选项差异。Apache-2.0 **不要求**开源本项目代码。
- **MIT（json-c）**：在副本或实质部分中保留版权声明与许可全文（`THIRD-PARTY-NOTICES.md` §3.2 已收录），随包分发即满足要求。
- **BSD-3-Clause（Go 运行时）**：二进制分发需复现版权声明、条件与免责声明（`THIRD-PARTY-NOTICES.md` §3.3），且不得以 Google LLC 或贡献者名义为产品背书。
- **打包流程已内置许可证复制（fail-closed）**：`scripts/package-app-dmg.py` 的 `assemble_app()` 调用 `copy_license_files()`，把三份文件复制到 `Contents/Resources/Licenses/`；该步骤发生在 `sign_bundle()` 之前，因此许可证文件被纳入代码签名范围。**缺源文件、空文件、复制后 sha256 与仓库根源文件不一致**都会在 `copy_license_files()` 内直接报错中止；`verify_layout()` 还会调用 `license_layout_problems()` 再查一遍：bundle 内缺文件、仓库根文件缺失、sha256 与仓库根不一致都会让打包失败，DMG 根本不会生成。

### 8.3 如何验证许可证随包分发

```sh
make app-dmg
ls -l dist/RDPServer.app/Contents/Resources/Licenses/     # LICENSE / NOTICE / THIRD-PARTY-NOTICES.md
cmp LICENSE dist/RDPServer.app/Contents/Resources/Licenses/LICENSE && echo 'LICENSE identical'
grep -q 'Apache License' dist/RDPServer.app/Contents/Resources/Licenses/LICENSE
codesign --verify --deep --strict dist/RDPServer.app      # 许可证文件在签名范围内
make test-app-bundle                                      # 含 "license files" 检查（size + markers + sha256）；项数由脚本动态打印
```

如需检查 DMG 内的最终形态（只读挂载，卷名 `RDP Server`）：

```sh
hdiutil attach -readonly -nobrowse dist/RDPServer-0.2.4.dmg
ls -l "/Volumes/RDP Server/RDPServer.app/Contents/Resources/Licenses"
hdiutil detach "/Volumes/RDP Server"
```

`scripts/test-app-bundle.py` 的 `license files` 检查（`check_licenses()`）是 **byte-for-byte** 校验：三份文件必须存在、size 不小于仓库根对应文件、包含关键标记（`LICENSE_MARKERS`：`LICENSE` 的 `Apache License`/`Version 2.0`/`END OF TERMS AND CONDITIONS`，`NOTICE` 的 `FreeRDP`/`OpenSSL`/`json-c`/`Go runtime`，`THIRD-PARTY-NOTICES.md` 的 `MIT`/`BSD-3-Clause`/`Apache-2.0` 以及从 `scripts/build-freerdp.sh` 现读的 FreeRDP 版本），并且 **sha256 必须与仓库根文件一致**（由 `sha256_file()` 现算）。期望值全部从当前仓库根文件现算，不硬编码行号或摘要。

> **`make test-app-bundle` 已覆盖 sha256 一致性**。因此修改 `LICENSE` / `NOTICE` / `THIRD-PARTY-NOTICES.md` 后**必须重新 `make app-dmg`**；否则旧 DMG 的 `license files` 检查会失败——这是刻意的 fail-closed 行为（防止发出与仓库声明不一致的许可证文本），不是随机 flake。同理，`dist/` 里若是**许可证复制逻辑之前构建的旧 DMG**，该检查也会失败属预期，重新 `make app-dmg` 后再验。

### 8.4 每次发布的合规清单

1. 仓库根的 `LICENSE`、`NOTICE`、`THIRD-PARTY-NOTICES.md` 非空、未被改名、内容与待发布版本一致（打包与 bundle 校验都会做 size/sha256 一致性检查；缺文件、空文件或内容不一致均硬失败）。
2. `make app-dmg` 后跑 `make test-app-bundle`，`license files` 项通过。
3. 发布说明写明：ad-hoc 签名、未公证、仅 arm64、最低 macOS 14.0；FreeRDP 未改源码、仅改构建选项；DMG 的 SHA-256。
4. 新增依赖先复核许可证；当前 7 个 dylib 全为 Apache-2.0/MIT，若引入 GPL/LGPL（如某些 OpenH264、GPL 版 FFmpeg 构建）必须重新评估分发义务。
5. 不得移除 FreeRDP/OpenSSL/json-c/Go 的归属信息；升级组件版本时同步更新 `THIRD-PARTY-NOTICES.md` 的版本与全文。

### 8.5 上游 FreeRDP NOTICE（仅追溯）

FreeRDP 3.32.2 归档内唯一的 `NOTICE` 位于 `winpr/libwinpr/sysinfo/cpufeatures/NOTICE`：AOSP 派生，NOTICE 正文为 Apache-2.0，源码头带有各自的 BSD-3-Clause 声明；该组件仅在 `ANDROID` 构建启用，macOS 不编译。其全文照录于 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) §3.4，用于完整保留上游归属声明；当前构建不包含该代码。

## 9. 可复现性边界

### 9.1 已固定的部分

- FreeRDP/WinPR **版本 + 归档 SHA-256**（`scripts/build-freerdp.sh`（`version`/`sha256`）），校验失败即中止；
- FreeRDP 的 CMake 选项集合（同脚本 :23-36）；
- 目标架构 arm64、部署目标 macOS 14.0；
- Go 模块版本声明（`go.mod` 的 `go` 指令）、SwiftPM 工具链 5.9（`native/macos/Package.swift` 的 `swift-tools-version`）；
- 无第三方包管理清单需要锁定（无 `go.sum`/`vendor/`、无 `requirements.txt`、无 `Package.resolved`；Pillow 仅图标脚本按需手工安装）。

### 9.2 未固定的部分（"同一台机器可重建"的边界）

| 项 | 风险 |
| --- | --- |
| Homebrew 公式版本（`openssl@3`、`json-c`、`cmake`、`pkgconf`、可选 `ffmpeg`） | 升级会改变头文件/ABI/产物字节；本机 OpenSSL 3.5.9、json-c 0.19 只是实测值 |
| Go 工具链 patch（本机 1.27.3） | 无 `toolchain` 指令，不同 patch 可能产生不同代码 |
| Swift / CLT / clang 版本 | 未固定；Xcode/CLT 升级会换 Swift 运行时与编译器 |
| macOS SDK | 默认用宿主 SDK（`xcrun --sdk macosx --show-sdk-path`）；**SDK 版本直接影响 FreeRDP 的 pipe2 探测**（§4.3） |
| 宿主 Homebrew 路径硬编码 | `scripts/test-protocol.py`（生成自签证书处） 与 `scripts/benchmark-fps.py`（`OPENSSL` 常量） 写死 `/opt/homebrew/opt/openssl@3/bin/openssl`；非 Apple Silicon Homebrew 前缀需改脚本（`scripts/disp-diagnose.py` 已有 `shutil.which` 兜底） |
| 时间戳与绝对路径 | Go/cgo 构建未使用 `-trimpath`，且二进制内嵌 `.deps/install` 绝对 rpath → 不同 checkout 路径/时间产生不同字节 |

### 9.3 已知的漂移证据（本机核对，说明"为什么不能宣称逐字节可复现"）

1. **Homebrew bottle 的 minos 高于目标**：本机 `libssl.3`/`libcrypto.3` 为 `minos 27.0`、`libjson-c.5` 为 `minos 26.0`，靠打包期 `vtool` 归一化到 14.0（`scripts/package-app-dmg.py` 的 `normalize_minimum_versions()`）。换一台 Homebrew 版本不同的机器，归一化前后的值都会变（归一化后应仍为 14.0，须复验）。
2. **同机多套 OpenSSL 主版本**：本机 Homebrew 同时有 `openssl@3`（3.5.9，`/opt/homebrew/opt/openssl@3`）与 `openssl@4`（4.1.0，`/opt/homebrew/opt/openssl` 指向它）。`.deps/build/CMakeCache.txt` 同时记录了 `OPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3` 与 pkg-config 探测到的 `/opt/homebrew/Cellar/openssl@4/4.1.0` 路径；产物**实际链接**以 `otool -L` 为准（当前为 `openssl@3` 的 `libssl.3`/`libcrypto.3`）。干净重建前建议删掉 `.deps/build`（或用新的 `FREERDP_BUILD_DIR`）并显式传 `OPENSSL_ROOT_DIR`。
3. **cgo 绝对 rpath**：`.deps/install/lib` 的绝对路径被写进二进制（`internal/worker/worker.go`（`#cgo LDFLAGS` 的 rpath）；本机 `bin/rdp-worker` 的 `LC_RPATH` 含完整 checkout 路径）。仓库换目录即需重建；这也是 `bin/` 产物不适合直接分发的另一个原因（DMG 打包会重写 rpath）。

### 9.4 重建与校验流程（建议）

```sh
# 1) 干净重建依赖（会删构建树，不影响源码归档；.deps 全部 gitignored）
rm -rf .deps/build
make deps

# 2) 依赖自检（§4.7）
make test-freerdp-sdk-selection
make test-freerdp-no-pipe2
nm -u .deps/install/lib/libwinpr3.3.dylib | grep -i pipe2   # 期望无输出
vtool -show-build .deps/install/lib/libwinpr3.3.dylib | grep minos   # 期望 14.0

# 3) 构建与默认测试
make build && make check
make agent-build && make agent-check

# 4) 打包并审计（发布前）
make app-dmg && make test-app-bundle
for f in dist/RDPServer.app/Contents/Frameworks/*.dylib \
         dist/RDPServer.app/Contents/Helpers/rdp-worker \
         dist/RDPServer.app/Contents/Helpers/rdpctl \
         dist/RDPServer.app/Contents/MacOS/RDPServer; do
  printf '%s: ' "$f"; vtool -show-build "$f" | grep minos
done
ls -l dist/RDPServer.app/Contents/Resources/Licenses/   # 许可证随包
shasum -a 256 dist/RDPServer-0.2.4.dmg
```

**结论**：当前是"**同一台机器、同一 Homebrew 状态**可重建"的开发流程；不是可分发级别、也不是逐字节可复现的构建。若要进一步提升（面向可复现发布），优先级建议：固定工具链版本（Go/Swift/CMake）、自建并固定 OpenSSL/json-c（或用 FreeRDP 内置实现/静态链接）、加 CI 与 `-trimpath`、把 FreeRDP 构建选项与许可证纳入发布流水线。

## 10. 相关文档

- 打包契约与 dylib 重定位细节：[docs/DESIGN-2026-11-08-app-packaging.md](DESIGN-2026-11-08-app-packaging.md)
- macOS 26/27 SDK 与 pipe2 修复证据：[docs/VERIFICATION-2026-11-09-macos26-sdk-build.md](VERIFICATION-2026-11-09-macos26-sdk-build.md)
- 当前状态/限制/测试基线：[docs/STATUS-2026-11-08.md](STATUS-2026-11-08.md)
- 分辨率协商契约：[docs/DESIGN-2026-11-07-resolution-adaptation.md](DESIGN-2026-11-07-resolution-adaptation.md)
- 第三方组件归属与许可证全文：[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)、[LICENSE](../LICENSE)、[NOTICE](../NOTICE)
- docs 目录索引：[docs/README.md](README.md)
- 仓库根入口：[README.md](../README.md)、[PLAN.md](../PLAN.md)
