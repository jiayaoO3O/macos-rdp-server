# macOS RDP Server（原型）

## English overview

A prototype RDP server for macOS: a Windows RDP client controls the desktop of the
user already logged in on the Mac. It does not provide remote login or unlock.

- Go + cgo + FreeRDP 3.32.2 worker: RDP, HYBRID NLA, bitmap, CLIPRDR/DISP.
- Swift agent: ScreenCaptureKit capture, CGEvent input, NSPasteboard clipboard.
- Swift menu bar app supervising worker/agent, packaged as a DMG.

Status: early **P0 prototype**, verified with Windows 11 `mstsc` over a LAN; one active
session; loopback-only by default. Not production-ready (ad-hoc signing, no notarization,
no remote login/unlock, no audio/file-system redirection). Apache-2.0 licensed.

## 项目简介

在 macOS 上运行 RDP 服务端，让已在本机完成登录的用户用 Windows RDP 客户端控制
**当前用户的桌面**。复用 FreeRDP 服务端内核，不重写 RDP 协议：Go 负责配置、认证门禁、
单连接租约与进程生命周期；Swift 负责 macOS 原生采集/输入/剪贴板；菜单栏 App 负责启停与权限。

当前是**开发原型（P0）**，不是可部署产品：只支持「本机已登录 → RDP 控制当前桌面」，远程登录、
解锁锁屏/FileVault、多用户并发均不在范围内；单活动连接，默认只监听 `127.0.0.1`。主验收客户端是
**Windows 11 `mstsc.exe`**；macOS Microsoft Windows App 为次要参考（基础画面/输入/剪贴板已实测）。

## 功能特性

验证等级：**真机验收** = 真实客户端连接并人工确认；**loopback** = 本机 FreeRDP
测试客户端协议验证；**实验性** = 默认不启用/未真机验证；**未实现** = 范围外。

### 连接与安全

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| HYBRID NLA 认证（NTLM/CredSSP 由 FreeRDP/WinPR 完成） | 真机验收 + loopback | 仅接受 HYBRID NLA；TLS-only、RDP security、RDSTLS、AAD、HYBRID_EX 均关闭 |
| 账号门禁（域固定 `MACRDP`）与单连接租约 | 真机验收 + loopback | 独立 RDP 密码；单活动会话，30s 无心跳可被新连接接管 |
| 无有效桌面帧时拒绝会话（fail-closed） | loopback + 真机 | 仅显式 `test_pattern: true` 时显示四色测试图 |
| 默认 loopback，局域网需显式开启 | 真机验收 | `allow_lan: true` 时只绑定单个 RFC1918 私有 IPv4，禁止 `0.0.0.0`/公网 |

### 画面、输入与剪贴板

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| ScreenCaptureKit 采集 + Planar 位图输出（64×64 dirty tile 增量） | 真机验收 | App 默认 SCStream + 60fps 目标 + 增量帧；只发变化块 |
| 键鼠注入（绝对坐标、Windows 方向滚轮、断线释放按键） | 真机验收 | Worker 原样转发桌面坐标，黑边映射在 Agent 内完成 |
| 键盘 Fn/flags 修复、双击/三击 | 真机验收 | 注入事件显式设置 flags 与 clickState |
| 文本/文件剪贴板双向（CF_UNICODETEXT、FileGroupDescriptorW/FileContents） | 真机验收 | 文件上限 100 个、单文件 <2 GiB、总计 ≤4 GiB；每次本地变化都重新通知客户端 |

### 分辨率与显示

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 连接时按客户端桌面框采集（16:9 虚拟显示器 + 镜像物理屏，断开自动恢复） | 真机验收 | 常见 2560×1440、1920×1080 无黑边；重连按新分辨率重建 |
| 显示排列（多显示器）快照/恢复 | 未实现（v1） | 当前只支持单个物理显示器 |
| 会话中拖动窗口实时改分辨率 | 已知限制（客户端） | 真实 mstsc 不发送 DISP monitor layout，新分辨率需重连 |

### 运行形态、平台与未实现

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 菜单栏 App + DMG（worker/agent、权限、账号、端口、局域网、日志） | 真机验收 | 版本 0.2.2；无 Dock 图标；数据目录 `~/Library/Application Support/RDPServer/` |
| 用户级 LaunchAgent 常驻 Agent（开发者/备用形态） | 已有自动化测试 | App 已自带 agent；两种形态不能同时占用 3389 |
| macOS 14.0+ / 仅 arm64 / macOS 26-27 `pipe2` 兼容 / 内置 MD4-RC4 | 构建 + 真机验收 + loopback | 包内 Mach-O 最低系统版本统一 14.0；构建期关闭 `WINPR_HAVE_PIPE2`；NLA 不依赖目标机 OpenSSL legacy provider |
| H.264/AVC420（GFX） | 实验性 | 需 `avc420` 构建标签与 FFmpeg 开发包；默认不含，未在真实客户端验证 |
| 远程登录/解锁、多用户、音频与文件系统重定向、RD Gateway | 未实现（范围外） | 只支持本机已登录用户、单活动连接、剪贴板文件传输 |

## 架构

```
Windows 11 mstsc.exe
   │ RDP / TLS / HYBRID NLA（单活动连接）
   ▼
rdp-worker（Go + cgo C）
   FreeRDP 3.32.2 服务端事件循环 · Planar 位图 · CLIPRDR/DISP · 单连接租约
   │ 私有 Unix socket（RDPA v1，0600，同 UID）
   ▼
rdp-agent（Swift，以登录用户身份运行）
   ScreenCaptureKit 采集 · CGEvent 键鼠注入 · NSPasteboard 文本/文件剪贴板

RDPServer.app（菜单栏 App）：启动/停止 worker 与嵌套 Agent，管理配置、RDP 凭据
（仅 NT 哈希）、自签证书、TCC 权限与日志。
```

Worker 是 socket 监听方，Agent 是连接方；一个 Worker 同时只接受一个 Agent 连接与一个活动 RDP
会话。屏幕录制/辅助功能的 TCC 身份是嵌套的 `RDPAgent.app`（`com.rdp-server.agent`），不是菜单栏 App。

## 系统要求与依赖

| 项 | 要求 |
| --- | --- |
| 系统 / 架构 | macOS **14.0+**；**Apple Silicon（arm64）**，不支持 Intel / universal2 |
| 工具链 / 本机依赖 | Xcode Command Line Tools（`swift`/`clang`，无需完整 Xcode）；Go **1.27**；CMake 4.x（实测可用）；Homebrew `openssl@3`（必需）、`json-c`/`pkgconf`（探测与 JSON 后端）；系统 `python3`（3.9+，脚本仅标准库；`scripts/generate-app-icon.py` 另需 Pillow，属可选开发依赖） |
| 网络 | 仅首次 `make deps` 需要联网下载 FreeRDP 3.32.2（约 11 MB，SHA-256 固定） |

版本矩阵、CMake 选项、第三方许可证与可复现性边界见
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)。

## 快速开始 A：安装菜单栏 App（推荐）

```sh
make deps          # 唯一联网步骤：下载并构建 FreeRDP 3.32.2 到 .deps/install
make app-dmg       # 生成 dist/RDPServer.app 与 dist/RDPServer-0.2.2.dmg
open dist/RDPServer-0.2.2.dmg
```

把 `RDPServer.app` 拖到 `Applications`，启动后无 Dock 图标，菜单栏出现 📟 状态图标（App 的 `AppIcon.icns` 已是自绘寻呼机图标；菜单栏仍用系统字体渲染的 📟 字形，不随包分发 emoji 位图）。

1. 「修改用户名和密码」：设置**独立的 RDP 账号与密码**（不是 Mac 登录密码；只存 NT 哈希）。
2. 需要其它机器连接时打开「允许局域网访问」；弹窗显示实际地址，默认仅 `127.0.0.1`。
3. 点「启用」，授予**屏幕录制**与**辅助功能**权限（TCC 身份是嵌套的 `RDPAgent.app`，授权后需重启采集）；从受保护目录复制文件到 Windows 还需**完全磁盘访问**（可选）。
4. Windows 11 `mstsc` 连接 App 显示的地址:端口（默认 3389），用户名 `MACRDP\<账号>`，接受自签证书提示。

无头检查（不启动服务；数据与日志目录见下节「安装、迁移与回滚」）：

```sh
"/Applications/RDPServer.app/Contents/MacOS/RDPServer" --status
"/Applications/RDPServer.app/Contents/MacOS/RDPServer" --self-test
"/Applications/RDPServer.app/Contents/MacOS/RDPServer" --version
```

`--self-test` 默认只检查隔离数据目录；`RDPSERVER_SELFTEST_START=1` 会临时启动并清理一套隔离的
worker+agent（随机端口，不碰正式数据）。

## 安装、迁移与回滚

- **Gatekeeper**：发布包为 ad-hoc 签名、未公证，从网络下载或换机后可能带 quarantine。
  首次启动若被拦截：
  1. 右键点击 `RDPServer.app` →「打开」，在弹窗中再次确认；或
  2. 「系统设置 → 隐私与安全性」→ 仍要打开。
  仅对你自己构建或信任的包使用
  `xattr -dr com.apple.quarantine /Applications/RDPServer.app`；不要对来源不明的包关闭隔离。
- **数据目录与迁移**：App 数据在 `~/Library/Application Support/RDPServer/`（0700；
  `RDPSERVER_DATA_DIR` 可覆盖），与开发者手工方式的 `.runtime/` 是**两套互不读写**的状态。
  切换形态前先停止服务；旧账号不会自动迁移，需在 App 内重新设置（SAM 只存 NT 哈希）。
  若旧 LaunchAgent `com.rdp-server.agent` 仍安装，它会反复重试旧 socket，建议先
  `python3 scripts/agent-launchd.py uninstall`；两套形态不能同时占用 3389。
- **回滚**：保留上一版 `RDPServer.app`/DMG。
  1. 退出当前 App（或弹窗「停止」）以停止服务；
  2. 用旧版替换 `/Applications/RDPServer.app`；
  3. 重新启动 App，并用包内可执行文件的 `--status` 确认状态正常。
  ad-hoc 重打包会改变 cdhash，可能需要重新授予屏幕录制/辅助功能。Worker 与嵌套 Agent
  必须**成对**升级/回滚，混版本（尤其文件剪贴板）可能导致 Agent 崩溃。
- **日志轮转**：日志为 `logs/{app,worker,agent}.log`；Worker 每帧一行（约 60 行/秒）。
  App **只在启动时**把超过 32 MiB 的日志轮转为 `.1`，长时间运行需自行关注体积
  （必要时重启 App 触发轮转）。
- **LAN 证书**：自签证书的 SAN 在服务启动时按当前地址生成；监听地址变化后证书不会热更新，
  客户端可能提示证书不符，重启服务/App 即可重新生成。局域网仅支持单个私有 IPv4，
  不支持 `0.0.0.0`/公网。

## 快速开始 B：开发者构建与手工运行

```sh
make deps          # 首次联网，构建 .deps/install
make build         # bin/rdp-worker、bin/rdp-probe、bin/rdpctl
make check         # Go race 测试 + C 策略 harness + go vet
make agent-build   # bin/rdp-agent
make agent-check   # Swift 纯逻辑测试
make agent-app     # bin/RDPAgent.app（TCC 身份，live 测试用）
```

`make build`、`make agent-build`、`make agent-app` 写入 `bin/`；
`make app-dmg` 写入 `dist/`，两者互不覆盖。

**B1. 四色测试图（纯 loopback，无需真实桌面）**

```sh
python3 scripts/dev-init.py                  # 交互设置独立 RDP 账号/密码
bin/rdp-worker -config .runtime/config.json  # 前台运行，Ctrl-C 停止
```

用 Windows 11 `mstsc` 连接 `127.0.0.1:3389`（或根目录生成的 `test-pattern.rdp`），
用户名 `MACRDP\<账号>`。`dev-init.py` 默认写入 `test_pattern: true`，画面是四色
矩形；输入只改变测试状态，不会注入本机桌面。

**B2. 真实桌面（手工 Agent）**

先把 `.runtime/config.json` 的 `test_pattern` 改为 `false`（需要剪贴板时同时设
`clipboard: true`），然后：

```sh
bin/rdp-worker -config .runtime/config.json
bin/RDPAgent.app/Contents/MacOS/rdp-agent status     # 检查 TCC 权限
bin/RDPAgent.app/Contents/MacOS/rdp-agent displays   # 查看 display index
export RDP_AGENT_CAPTURE_STREAM=1 RDP_AGENT_DELTA_FRAMES=1 \
       RDP_AGENT_TARGET_FPS=60 RDP_AGENT_VIRTUAL_DISPLAY=1
bin/RDPAgent.app/Contents/MacOS/rdp-agent stream-snapshot \
  "$(pwd)/.runtime/agent.sock" 0 0 1
```

`stream-snapshot` 参数依次为：socket 路径、display index、持续秒数（`0` = 持续到进程
退出）、generation（>0 且递增）。Worker 的 `-agent-socket` 必须与该 socket 一致；Worker
异常退出后重启前要删除残留 socket。需要常驻 Agent 又不启动菜单栏 App 时，可用
`python3 scripts/agent-launchd.py install --socket <绝对路径>`（用户级 LaunchAgent）。

## 安全模型与隐私

- **仅 HYBRID NLA**：TLS-only、标准 RDP security、RDSTLS、AAD 与 HYBRID_EX 均显式关闭。
- **独立 RDP 密码**：不是 Mac 登录密码；SAM 只保存 NT 哈希（密码等价物，不要提交或外传）。
- **单活动连接**：同一时间只允许一个会话；租约 30s 无心跳可被新连接接管，旧连接的释放/
  心跳不影响新连接（第二次登录被拒时客户端常显示 `0x904`，不是密码错误）。
- **默认 loopback + fail-closed**：局域网模式必须显式开启且只绑定单个私有 IPv4；没有 Agent
  的有效桌面帧时拒绝会话，绝不回退显示其他桌面。
- **自签证书**：首次连接会提示证书不受信任，应人工核对指纹后接受；SAN 在服务启动时按当前地址生成，地址变化后需重启服务。
- **日志**：只记录脱敏元数据（事件名、尺寸、计数、错误码），不记录凭据、剪贴板内容或完整
  用户文件路径；传输 dump / 输入 trace 默认关闭，只应在隔离环境短时开启。
- **不绕过系统安全**：不关闭 SIP、不修改 TCC 数据库、不安装内核驱动或系统级服务。

## 已知限制

- **会话中拖动窗口不会实时改分辨率**：真实 `mstsc` 不发送 DISP monitor layout；换分辨率
  请重连（会按新桌面框重建虚拟显示器）。
- **无物理显示器时**（笔记本合盖且无外接屏）不创建虚拟显示器，回退 fit-with-bars，可能带黑边。
- **多显示器**仅支持单物理显示器；排列快照/恢复未实现。
- **不做**远程登录/解锁、多用户并发、音频重定向、文件系统重定向、RD Gateway。
- **分发形态**：ad-hoc 签名、未公证、仅 arm64；其它机器首次打开可能需右键「打开」或重新
  授权。无自动更新、无系统级安装器。
- **AVC420/H.264** 仍为实验性路径，默认构建不含，未在真实客户端验证。
- **无头/合盖主机 + 外接 4K 16:9 显示器**的目标环境尚未真机验证。
- 文件剪贴板读取受保护目录需要给嵌套 Agent 授予完全磁盘访问；ad-hoc 重打包后可能需要重新授权。
- 60fps 是配置目标而非真机结论（历史 loopback 整链：交互式约 57fps、全屏运动约 13fps）；
  真实客户端渲染帧率尚未做脚本化测量。

## 测试

仓库**没有 CI**，所有检查在本地手工运行；提交前至少跑与改动相关的目标。
`.deps/install` 缺失时，Go/cgo 与 C harness 会直接失败。

| 命令 | 覆盖 | 前置 / 说明 |
| --- | --- | --- |
| `make check` | Go race 测试、C 图形/编码策略 harness、`go vet` | 需要 `.deps/install` |
| `make test-protocol` | loopback 协议 E2E（约 35 例，约 90–100s） | 依赖 `make build`（会写 `bin/`）；需要本机 TCP 监听 |
| `make agent-check` | Swift 纯逻辑：IPC、增量帧、几何/坐标、键盘/鼠标、剪贴板 | 仅需 Swift 工具链 |
| `make test-agent-ipc-wire` / `test-agent-launchd` | Unix socket IPC 收发；LaunchAgent plist/generation/权限退出 | Swift 工具链 |
| `make test-app` / `make app-dmg` + `test-app-bundle` | App 核心契约；打包与 DMG 只读挂载校验 | 后者需要 `.deps/install` |
| `make test-virtual-display` | 虚拟显示器创建/采集/重连/恢复（6 例） | **会短暂改变真实显示排列**，结束时恢复 |
| `make test-freerdp-sdk-selection` / `test-freerdp-no-pipe2` / `test-worker-auto-lan` | macOS 26/27 SDK 与 `pipe2` 构建配置；`address: "auto"` 局域网地址发现 | 无网络；后者需要私有 LAN 接口 |
| `make test-windows-app-smoke` | Windows App 设备卡冒烟日志判定 | 需要 Windows App、辅助功能权限；不自动点击真实客户端 |
| `python3 scripts/test-clipboard-handshake.py` | C 剪贴板 helper（6 例） | 需要 `.deps/install` |
| `python3 scripts/benchmark-fps.py` / `benchmark-live-agent.py` | loopback 服务端帧率基准（假 Agent / 真实 Agent） | 需要 `bin/`；**不是**真实客户端渲染 FPS |

2026-11-09 的参考基线：协议 E2E 35 例（1 例 AVC420 skip）、打包 App `--self-test` 28 项通过。
`make test-app-bundle` 默认执行 **17 个命名检查 + 1 个 shared 信息项**（summary 约 18 checks）；
`--skip-service-check` 会跳过其中需要临时启动打包 worker 的 1 项（命名检查 16 passed + 1 skipped，
summary 通常 17 passed + 1 skipped）。注意：当前 0.2.2 DMG 构建于「许可证随附」逻辑之前，
`license files` 检查需重新 `make app-dmg` 后才会通过；干净副本已用 `--skip-service-check`
验证 17 passed / 1 skipped。实验性 AVC420 另有 `make test-avc420-build` / `test-avc420-gfx-probe`
（需 FFmpeg 开发包）。不可自动化的部分（真实客户端画面/手感、TCC 弹窗与持久性、Gatekeeper
首启流程）必须人工验收。

## 项目结构

```
cmd/                Go 入口：rdp-worker、rdp-probe（loopback 测试客户端）、rdpctl（NT 哈希）
internal/           Go 逻辑：worker（cgo/C 事件循环）、auth（租约）、config、agentipc
native/macos/       SwiftPM：MacAgentCore、rdp-agent、RDPServerCore、RDPServer（菜单栏 App）
native/freerdp/     cgo 适配层的所有权/线程/安全约束说明
scripts/            Python/shell：构建、初始化、测试、打包、诊断、LaunchAgent
docs/               设计/诊断/验证/状态/依赖文档（入口见 docs/README.md）
Makefile            统一构建与测试入口
```

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/README.md](docs/README.md) | 文档总索引与命名规范 |
| [docs/STATUS-2026-11-08.md](docs/STATUS-2026-11-08.md) | 当前实现状态、可用范围、测试基线（状态冲突时以此为准） |
| [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) | 版本矩阵、构建选项、第三方许可证、可复现性边界 |
| [PLAN.md](PLAN.md) / [AGENTS.md](AGENTS.md) | 产品范围与路线 / 贡献者与代理工作纪律、关键契约 |
| DESIGN 设计契约（6 篇） | [分辨率/鼠标](docs/DESIGN-2026-11-07-resolution-adaptation.md)、[虚拟显示器](docs/DESIGN-2026-11-08-virtual-display.md)、[文件剪贴板](docs/DESIGN-2026-11-08-clipboard-files.md)、[菜单栏 App](docs/DESIGN-2026-11-08-menu-bar-app.md)、[菜单栏 UI](docs/DESIGN-2026-11-08-menu-bar-ui.md)、[打包](docs/DESIGN-2026-11-08-app-packaging.md) |
| DIAGNOSIS 诊断记录（3 篇） | [DISP 客户端限制](docs/DIAGNOSIS-2026-11-08-disp-window-resize.md)、[键盘 Fn/flags](docs/DIAGNOSIS-2026-11-08-keyboard-swallowed-input.md)、[虚拟显示器鼠标偏移](docs/DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md) |
| [docs/VERIFICATION-2026-11-09-macos26-sdk-build.md](docs/VERIFICATION-2026-11-09-macos26-sdk-build.md) | macOS 26/27 `pipe2` 构建验证 |
| [docs/VERIFICATION-2026-11-08-final-acceptance.md](docs/VERIFICATION-2026-11-08-final-acceptance.md) | 最终真机验收记录（Windows 11 `mstsc` 逐项、自动化基线与制品校验） |
| `docs/archive/`、`docs/validation/` | 早期设计与阶段验收记录（历史证据，结论可能已被 STATUS 取代） |

本仓库不使用交接类（HANDOFF）文档：状态写在 STATUS/README/AGENTS，历史证据写在
VERIFICATION/DIAGNOSIS；早期交接记录已移除，本索引不再包含。

## 贡献与许可证

- **许可证**：[Apache License 2.0](LICENSE)。第三方组件与再分发义务见 [NOTICE](NOTICE)
  与 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)（FreeRDP/WinPR、OpenSSL、json-c，
  以及静态链接的 Go 运行时）。
- **改动前**：先读 [AGENTS.md](AGENTS.md) 的代码约定与关键契约；本项目刻意保持 Go 零第三方
  依赖、Python 脚本仅标准库（图标生成脚本可选依赖 Pillow）、Swift 无 SPM 依赖。
- **提交前**：至少运行 `make check`；改动 Worker/C 协议路径再加 `make test-protocol`；
  改动 Swift 跑 `make agent-check` 与相关 harness。项目没有 CI，测试结果需本地确认；改动
  行为/命令/范围时同步更新 README、AGENTS.md 与 docs/STATUS-2026-11-08.md。
- **安全问题**：请通过 GitHub Security Advisories（或维护者提供的私下渠道）报告，不要在
  公开 Issue 中粘贴凭据、内网地址或可复现的攻击细节。
