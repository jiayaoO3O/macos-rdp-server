# AGENTS.md — AI 编码代理入口

> 本文件面向在 `rdp-server` 仓库工作的 **AI 编码代理**（以及新贡献者）。它只讲**事实来源、契约、纪律与陷阱**；人类上手步骤（安装 DMG、连接 Windows 客户端）见 [README.md](README.md)。
>
> 阅读顺序：**本文件 → [docs/STATUS-2026-11-08.md](docs/STATUS-2026-11-08.md)（当前状态权威）→ [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)（版本/构建/许可证）**。文档索引见 [docs/README.md](docs/README.md)。

## 0. 事实卡片

| 项 | 事实 |
| --- | --- |
| 项目 | macOS RDP **早期原型**：让已在本机登录的 Mac 用户用 Windows RDP 客户端控制**当前用户桌面** |
| 语言 | Go 1.27（无第三方 Go 依赖）+ cgo C（FreeRDP/WinPR 3.32.2）+ Swift（SwiftPM tools 5.9）+ Python 3（脚本仅标准库；图标脚本可选 Pillow）+ Makefile |
| 形态 | 菜单栏 App `RDPServer.app` 自管 worker + 嵌套 Agent（推荐/已验收）；手工 `bin/rdp-worker` + Agent / LaunchAgent 为开发者形态 |
| 版本 | `0.2.4`（`native/macos/Sources/RDPServerCore/Version.swift`） |
| 平台 | Apple Silicon / arm64（仅）；最低 **macOS 14.0**；macOS 26/27 构建兼容见 DEPENDENCIES §4.3 |
| 依赖 | FreeRDP/WinPR **3.32.2**（归档 SHA-256 固定）、Homebrew `openssl@3`、`json-c`、`pkgconf`、CMake 4.x（实测可用）、Xcode Command Line Tools（无需完整 Xcode） |
| 许可证 | 项目 **Apache-2.0**；FreeRDP/WinPR 与 OpenSSL 为 Apache-2.0，json-c 为 MIT，Go runtime 为 BSD-3-Clause（静态链接进 helper；见 `THIRD-PARTY-NOTICES.md`） |
| 默认监听 | `127.0.0.1:3389`；局域网需显式 `allow_lan:true` + 单个 RFC1918 私有 IPv4 |
| 数据目录 | App：`~/Library/Application Support/RDPServer/`（0700）；手工形态：`.runtime/`（0700）——两套互不读写 |
| 客户端 | Windows 11 `mstsc.exe`（**主验收客户端**）；macOS Microsoft Windows App（次要，已实测） |
| 状态/依赖/索引 | [docs/STATUS-2026-11-08.md](docs/STATUS-2026-11-08.md) / [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) / [docs/README.md](docs/README.md) |

## 1. 当前状态与验证等级

证据优先序：**代码 > STATUS > DESIGN/VERIFICATION/DIAGNOSIS > README/AGENTS/PLAN 的状态描述**。缩写：真机=真实 RDP 客户端连接并人工确认；loopback=`scripts/test-protocol.py` 的协议 E2E；自动化=单测/harness/bundle 校验。

- **真机验收**：HYBRID NLA、账号门禁、单连接租约；live 桌面采集（ScreenCaptureKit）→ 64×64 dirty tile 增量 → Planar 位图；键鼠（鼠标桌面坐标原样转发、边缘/黑边对齐、双击/三击、滚轮 Windows 方向、断线释放全部按键）；文本剪贴板双向、文件剪贴板双向；连接时按客户端桌面框建 16:9 虚拟显示器（1:1、无黑边/拉伸、断开/崩溃恢复显示排列、重连按新尺寸重建）；菜单栏 App + DMG 安装与运行。
- **loopback / 自动化**：35 例协议 E2E（1 例 AVC420 skip）、Go race/vet、Swift 纯逻辑、C 策略/编码器 harness、App 核心与生命周期、DMG/bundle 校验、打包 App `--self-test`。
- **实验性（默认构建不含）**：H.264/AVC420（`avc420` build tag + `RDP_ENABLE_AVC420=1`，需手工 `.deps/install-h264`）；NSCodec/raw bitmap 仅测试路径。
- **未实现 / 范围外**：远程登录 macOS、解锁锁屏/FileVault、登录窗口桥接；多用户并发/跨用户接管；音频重定向、文件系统重定向；多显示器排列快照/恢复；Developer ID 签名/公证、系统 LaunchDaemon、限流/失败锁定/审计。
- **性能口径**：60 fps 是**配置目标**，不是已验证的客户端渲染帧率；交互式局部变化 loopback 整链实测约 57 fps，全屏运动受 Planar 编码 CPU 限制（约 13 fps，2026-11-07 记录）。不要宣称“真机 60 fps 已验收”。

**已知限制**（细节与证据见 STATUS §2）：

- 会话中拖动窗口实时改分辨率不可用——真实 mstsc 不发 DISP monitor layout（服务端 DISP 已实现并有诊断日志）；改分辨率请重连。
- 无物理显示器（MacBook 合盖且无外接屏）时虚拟显示器自动跳过，回退 fit-with-bars（可能黑边）。
- 多显示器排列快照/恢复为 v1 简化；无头 Mac mini + 外接 4K 16:9 路径尚未真机验证。
- 文件剪贴板读受保护目录需给嵌套 `RDPAgent.app` **完全磁盘访问**；ad-hoc 重打包后 cdhash 变化可能需重新授权 TCC。
- ad-hoc 签名、未公证、仅 arm64；干净机器首次启动的 Gatekeeper/TCC 流程未验证。

## 2. 范围与硬边界

首阶段**只支持**：Mac 用户先在本机完成登录，然后通过 RDP 控制**当前登录用户自己的桌面**。

- **明确不做**：远程登录/解锁/FileVault、登录窗口桥接、多用户并发、跨用户桌面接管、音频/文件系统重定向、RD Gateway/云端中继/公网穿透、任何非 HYBRID NLA 的认证（TLS-only、RDP security、RDSTLS、AAD、HYBRID_EX）。
- **认证**：域固定 `MACRDP`；独立 RDP 密码（SAM 只存 NT 哈希，是密码等价物）；**不是** Mac 登录密码；禁用账号拒绝租约。
- **网络**：默认 `127.0.0.1`；`allow_lan:true` 只允许单个 RFC1918 私有 IPv4；禁止 `0.0.0.0`/公网/端口转发暴露。
- **fail-closed**：无 Agent 有效帧时**拒绝** RDP 会话；绝不回退显示其他用户桌面或测试图（测试图必须显式 `test_pattern:true`）。
- **系统边界（不可协商）**：不绕过 TCC、不关闭 SIP、不修改系统隐私数据库、不安装系统服务/驱动、不开启自动登录、不修改系统屏幕共享配置。

## 3. 仓库地图

| 路径 | 内容 |
| --- | --- |
| `cmd/rdp-worker` | Worker 入口（`-config`、`-agent-socket` 两个 flag；`address:auto` 时 fork 子进程做 LAN 地址监督） |
| `cmd/rdp-probe` | loopback 专用无头 FreeRDP 测试客户端（模式 0–12，见 `scripts/test-protocol.py`） |
| `cmd/rdpctl` | 仅 `hash-stdin`：用 WinPR 计算 NT 哈希（供 `dev-init.py`/App 生成 SAM） |
| `internal/worker` | cgo 适配 + FreeRDP 服务端事件循环/图形/输入/CLIPRDR/DISP/IPC（`native.c`，生产逻辑几乎全在 C） |
| `internal/auth` | principal 规范化与单连接租约 `Gate` |
| `internal/config` | 配置解析/校验、`address:"auto"` LAN 发现 |
| `internal/agentipc` | RDPA v1 的 Go 参考实现与测试模型（**未被生产代码 import**；权威在 Swift + C） |
| `native/macos/Sources/MacAgentCore` | 纯逻辑 Swift（IPC codec、delta 编码、几何/坐标、键鼠状态机、剪贴板、虚拟显示器会话） |
| `native/macos/Sources/rdp-agent` | Agent CLI：采集循环、输入注入、剪贴板、socket、信号 |
| `native/macos/Sources/RDPServerCore` | 菜单栏 App 核心（Foundation-only）：生命周期、路径/私密文件、配置/证书、权限、日志、自检、CLI |
| `native/macos/Sources/RDPServer` | 菜单栏 App（AppKit NSStatusItem + NSPopover + SwiftUI 视图） |
| `native/freerdp/README.md` | cgo 适配层所有权/线程/安全约束（改 native 层前必读） |
| `scripts/` | 构建/初始化/测试/基准/诊断/打包脚本（Python 标准库为主） |
| `Makefile` / `go.mod` / `README.md` / `PLAN.md` | 统一构建入口 / 模块 / 人类入门 / 范围与路线 |

生成物与私有状态（**已 gitignore，绝不提交**）：`.deps/`（FreeRDP 构建/安装）、`.cache/`（Go 缓存）、`.runtime/`（手工形态配置/SAM/证书/socket/日志）、`bin/`（构建产物）、`native/macos/.build/`（Swift 输出）、`dist/`（App/DMG）、`.worktrees/`。完整规则见 `.gitignore`。

## 4. 构建与测试

### 4.1 前置依赖

| 依赖 | 要求 |
| --- | --- |
| 硬件/系统 | Apple Silicon；**macOS 14.0+**（开发/目标机另有 macOS 26/27，见下） |
| Xcode CLT | `swiftc`/`clang`（不需要完整 Xcode；本机 CLT-only 工具链无 SwiftUI 宏插件） |
| Go | 1.27+（`go.mod` 声明 `go 1.27`；无第三方模块） |
| CMake | 4.x（构建 FreeRDP） |
| Homebrew | `openssl@3`（必需）、`json-c`、`pkgconf` |
| Python | 3.9+（系统 `/usr/bin/python3`；脚本仅标准库；图标脚本可选 Pillow） |
| FFmpeg | 可选，仅 AVC420 实验路径 |

完整版本矩阵、每条声明的出处、许可证与可复现性边界见 **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)**。

### 4.2 make 目标速查

| 目标 | 作用 / 注意 |
| --- | --- |
| `make deps` | 下载+校验+CMake 构建 FreeRDP 3.32.2 → `.deps/install`。**唯一联网构建步骤**；不要并发跑 |
| `make build` | `go build -o bin/ ./cmd/...`。**覆盖 `bin/`**（若 `bin/` 正在服务真实会话，勿跑） |
| `make check` | `make test` + C gfx harness + AVC 编码器 harness + `go vet`（**不含** protocol/bundle） |
| `make test` | `go test -race ./...`；需 `.deps/install`；会命中缓存，要新鲜结果加 `-count=1` |
| `make test-protocol` | 依赖 `make build`，跑 35 例 loopback E2E（~90–100 s）；会覆盖 `bin/` |
| `make agent-build` / `agent-check` | 构建 `bin/rdp-agent` / 用 `swiftc` 编译手写清单并跑纯逻辑测试 |
| `make agent-app` | 打包 ad-hoc 签名 `bin/RDPAgent.app`（TCC 身份；部署 Agent 的正确产物） |
| `make app-build` / `app-dmg` | Swift release 构建（含菜单栏 App）/ 组装 `dist/RDPServer.app` + `dist/RDPServer-0.2.4.dmg`（不覆盖 `bin/`） |
| `make test-app` / `test-app-bundle` | App 核心无头契约 / 只读挂载 DMG 的 bundle 校验（项数以脚本为准） |
| `make test-virtual-display` | 虚拟显示器集成 harness（6 例）。**会短暂切换真实显示排列**，有活动用户会话时勿跑 |
| `make test-freerdp-sdk-selection` / `test-freerdp-no-pipe2` | 守护 macOS 26/27 SDK 选择与 `WINPR_HAVE_PIPE2=OFF` 构建配置 |
| `make test-agent-ipc-wire` / `test-agent-launchd` / `test-worker-auto-lan` | IPC 线格式 / LaunchAgent plist / `address:auto` |
| `make test-windows-app-smoke` / `test-performance-baseline` | 日志判定器单测 / 性能日志统计单测（都不启动真实客户端） |

### 4.3 首次构建顺序

```sh
make deps        # 唯一联网步骤（分钟级）
make build       # bin/rdp-worker、bin/rdp-probe、bin/rdpctl
make check       # Go race + C/AVC harness + vet
make agent-build && make agent-check
make agent-app   # bin/RDPAgent.app（TCC 身份）
make app-dmg     # 可选：dist/RDPServer.app + dist/RDPServer-0.2.4.dmg
make test-app-bundle   # 可选：发布前 bundle 校验
```

- **`.deps/install` 缺失时 cgo 直接编译失败**；`make build/check/test-*` 不会自动触发 `make deps`。
- 需要验证新代码但 `bin/` 正在服务真实会话时：将独立构建输出放在系统批准的临时目录（例如 `$TMPDIR/rdp-check/`），再设 `RDP_TEST_WORKER_BINARY`/`RDP_TEST_PROBE_BINARY` 跑协议测试；改动另存于独立 worktree 时需先 `ln -s <主仓库>/.deps .deps`。
- 依赖重建/证明可复现性的完整命令见 DEPENDENCIES §9（`vtool -show-build` 审计 minos=14.0、`nm -u` 查 `_pipe2`）。
- **当前没有 CI**：提交前必须按改动范围在本地跑测试（§9），并在回复/PR 中写明跑了什么、什么没跑。

## 5. 架构与关键契约

### 5.1 运行时拓扑

```
 Windows 客户端 ──RDP/TLS/HYBRID NLA（单活动连接）──▶ bin/rdp-worker（Go + cgo C，FreeRDP 事件循环）
                                                          │  私有 Unix socket（RDPA v1，0600，同 UID）
                                                          ▼
                                              RDPAgent.app 内 rdp-agent（Swift）
                                              ScreenCaptureKit 采集 / CGEvent 输入 / NSPasteboard 剪贴板
```

- Worker 是 socket 的 **listener**，Agent 是 client；一个 Worker 同时只接受**一个** Agent 连接与一个活动 RDP 会话。
- Worker 与 Agent 是**硬匹配对**（尤其文件剪贴板 IPC）：混版本部署可能导致崩溃，部署/回滚必须两端同一窗口完成。

### 5.2 Worker ↔ Agent IPC（RDPA v1）

- 传输：AF_UNIX `SOCK_STREAM`；socket 必须**绝对路径**、UTF-8 字节数 < 104、位于当前 UID 拥有的 0700 目录，文件 0600，`getpeereid` 校验同 UID。**启动时若 socket 路径已存在，C 侧会静默放弃监听**（不报错，表现为会话激活被拒 `reason=no_frame`）；Worker 被 SIGTERM/崩溃不会 unlink socket。
- 封装：12 字节头 `"RDPA"(4) + u16 version=1 + u16 type + u32 BE payloadLen`；payload ≤ 64 KiB，多字节字段大端。
- 消息类型（完整字段以 Swift `AgentIPCMessage.swift` + C `native.c` 为准）：

| type | 含义 / 方向 |
| --- | --- |
| 1, 4, 5, 6 | 保留未使用（release-all 实际用 3 + kind=4） |
| 2 + 7 | 旧整帧路径：frameReady(25B 元数据) + frameChunk(20B 头 + 像素；offset 必须严格连续) |
| 3 | inputEvent（9B：kind/flags/code/x/y；kind 1 鼠标、2 scancode、3 unicode、4 releaseAll）：Worker→Agent |
| 8 | 文本剪贴板（Agent→Worker `[1]+UTF-8`；Worker→Agent `[2]+UTF-16LE`） |
| 9 | captureSize（Worker→Agent，桌面框尺寸） |
| 10/11/12 | delta 帧 begin/chunk/end（64×64 tile） |
| 13–16 | 文件剪贴板 offer begin / chunk / offer end / entry |
| 17 | displayRestore（空 payload，恢复显示排列） |

- **generation 非递减**、同一 generation 内 **frameID 严格递增**（C 侧 stale 判定）；Agent 重启必须使用更大的 generation。
- 限制：整帧 ≤ 64 MiB、宽高 ≤ 16384、单 chunk 数据 ≤ 65516、payload ≤ 64 KiB；文件剪贴板 ≤ 100 文件、单文件 < 2 GiB、总 ≤ 4 GiB；文件名必须是安全单路径组件（禁 `/` `\` `:` 控制字符 `..`）；符号链接/非普通文件拒绝。
- 生产路径整帧 bpp 必须恰好 4；**未知消息类型必须忽略并限频记日志**（抛错会杀死接收线程）。

### 5.3 配置（`internal/config/config.go`）

JSON 单对象，**未知字段被拒绝**（`DisallowUnknownFields`）；文件必须 0600、父目录 0700 且属当前 UID，否则 Worker 拒绝启动。

| 字段 | 约束 / 默认 |
| --- | --- |
| `address` | `127.0.0.1`，或 `allow_lan:true` 下的私有 IPv4，或 `"auto"`（要求 `allow_lan:true`，只选唯一私有地址，无合格接口失败关闭） |
| `allow_lan` / `port` | 默认 false / 3389；端口 1024..65535 |
| `account` | 小写裸 MACRDP principal |
| `enabled` / `test_pattern` / `clipboard` | 禁用即拒绝租约；测试图仅显式 true；clipboard 默认 **false**（菜单栏 App 默认 **true**） |
| `certificate` / `key` / `sam` | 绝对路径普通文件 0600，父目录私有；SAM 格式 `account:MACRDP::<NT hash>:` |

运行时开关（节选，完整表见 DEPENDENCIES 与代码）：

| 变量 | 作用域 | 默认 |
| --- | --- | --- |
| `RDP_AGENT_TARGET_FPS` / `RDP_AGENT_CAPTURE_STREAM` / `RDP_AGENT_DELTA_FRAMES` | Agent | 30 / 关 / 关（App 设 60 / 1 / 1） |
| `RDP_AGENT_VIRTUAL_DISPLAY` | Agent | **关**，仅字面 `"1"` 开（App 设 1） |
| `RDP_AGENT_MATCH_DISPLAY_MODE` | Agent | **开**，仅 `"0"` 关；虚拟显示器路径下不生效 |
| `RDP_AGENT_STUCK_MODIFIER_GUARD` | Agent | 开，`"0"` 关（保守释放卡住修饰键） |
| `RDP_AGENT_CLIPBOARD_STAGING` / `RDP_AGENT_NO_PERMISSION_REQUEST` | Agent | 关 / 未设 |
| `RDP_AGENT_INPUT_TRACE` / `RDP_AGENT_EVENT_TAP` | Agent 诊断 | 关（采样后删除含键码日志） |
| `RDP_WORKER_MANAGED_BY_APP` | Worker（App 形态内部） | App 设 `1`；父进程变成 PID 1（App 崩溃/SIGKILL）时记录 `event=worker_parent_exited` 并退出；手工/launchd 形态不设，生命周期不变 |
| `RDP_WORKER_BACKTRACE` / `RDP_DISP_DEBUG` / `RDP_INPUT_TRACE` | Worker 诊断 | 关 |
| `RDP_TRANSPORT_DUMP` / `WLOG_LEVEL` | Worker 诊断 | 关：dump 含会话流量，仅隔离测试短时使用 |
| `RDPSERVER_DATA_DIR` / `RDPSERVER_HELPERS_DIR` / `RDPSERVER_SELFTEST_START` | App | 数据目录 / helper 目录 / 自检开关 |

### 5.4 认证与租约

- 只接受 **HYBRID NLA**；NTLM/CredSSP 由 FreeRDP/WinPR 完成，Go 不实现 NTLM；SAM 只存 NT 哈希（禁止明文/日志/命令行）。
- 只有**已认证 Logon 回调**才能获取租约；TLS/NLA 握手 deadline 15 s、发帧 deadline 5 s；单连接租约 1 s 心跳、30 s 无心跳可被接管；旧 token 的释放/心跳被忽略。
- `MAX_PEERS=4` 只是握手线程槽，**不是**会话数上限。

### 5.5 分辨率、布局与鼠标

- 客户端请求的桌面尺寸 = 协商尺寸（超限等比 clamp）；Agent 按 `exact`/`fit`/`native` 策略采集（永不放大超过原生像素）；Worker 按 fit-with-bars 把采集内容合成到桌面框。
- **fit-with-bars 的整数算法必须在 C Worker / Swift Agent / Python 测试三处逐位一致**；改一处必须同步另外两处与测试期望。
- 鼠标：Worker 把**桌面坐标原样**（仅 clamp）发给 Agent；Agent 负责 `desktop → capture 像素 → 显示器 points` 映射；不要在 Worker 侧再缩放（历史双重缩放导致边缘漂移）。
- **输入 display target 契约（2026-11-09）**：虚拟显示器 active 且其 bounds 尺寸（四舍五入）== capture 尺寸时，注入必须用虚拟屏的 displayID 与 `CGDisplayBounds`；否则回退启动物理屏 bounds。诊断日志 `event=input_target source=virtual|physical`、`event=input_target_fallback reason=bounds_mismatch|display_unavailable`。改此契约必须同步 `InputDisplayTargetResolver` 单测与日志。
- 采集尺寸变化会更新 Geometry；Agent 重连时 Worker 用 type 9 重发当前桌面框尺寸。

### 5.6 剪贴板

- 文本：`CF_UNICODETEXT`；文件：`FileGroupDescriptorW`/`FileContents`。
- **方向编号语义相反**：文本 IPC 标记 1=local→remote、2=remote→local；文件 return direction 1=Windows→macOS、2=macOS→Windows。不要“统一”两套编号。
- 文件落地：Agent 只写 `NSTemporaryDirectory()/rdp-clipboard*/`（0700 目录/0600 文件、`O_EXCL|O_NOFOLLOW`），限制数量/大小并清理；Worker 侧同样做范围/路径校验。
- 剪贴板日志不得打印文本内容或完整用户路径（可记 basename + errno）。

### 5.7 权威文件（改契约前先读）

- IPC：`native/macos/Sources/MacAgentCore/AgentIPCMessage.swift` + `internal/worker/native.c`
- 分辨率/布局/鼠标：[docs/DESIGN-2026-11-07-resolution-adaptation.md](docs/DESIGN-2026-11-07-resolution-adaptation.md)
- 文件剪贴板：[docs/DESIGN-2026-11-08-clipboard-files.md](docs/DESIGN-2026-11-08-clipboard-files.md)
- 虚拟显示器：[docs/DESIGN-2026-11-08-virtual-display.md](docs/DESIGN-2026-11-08-virtual-display.md)
- App 生命周期/UI/打包：`docs/DESIGN-2026-11-08-menu-bar-app.md`、`-menu-bar-ui.md`、`-app-packaging.md`
- cgo 所有权/线程：[native/freerdp/README.md](native/freerdp/README.md)

## 6. 运维红线

> 若你在一台**正在服务真实 RDP 会话**的机器上工作，以下规则优先级最高。

1. **重启 Worker = 断开用户的 RDP 会话**：没有明确同意不要停止/重启 Worker，也不要 `rm` 正在使用的 socket。App 形态下由 App 管理 worker/agent（弹窗“停止/退出”）；可选 LaunchAgent 形态下单独重启 Agent（`launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent`）不断会话，但仍会短暂断帧。
2. **socket 残留**：Worker 被 SIGTERM/崩溃不会 unlink socket；确认 Worker 已退出后必须 `rm -f` 旧 socket 再启动，否则 C 侧静默放弃 Agent 监听（`reason=no_frame`）。App 形态由 App 自己在启动 Worker 前 unlink。
3. **成对部署**：Worker 与 Agent 同一窗口升级/回滚；文件剪贴板混版本可能崩溃。
4. **两种形态互斥**：菜单栏 App 与手工 worker/旧 LaunchAgent 不能同时占用同一端口；两套数据目录互不读写。App 形态由 App 管理进程（停止顺序：先 Agent 后 Worker 并清理 socket）。
5. **TCC**：需要屏幕录制 + 辅助功能的身份是**嵌套 Agent**（`RDPAgent.app`，bundle id `com.rdp-server.agent`），不是菜单栏 App；ad-hoc 重打包会改 cdhash，可能需重新授权。检查权限用 app 内可执行文件（`bin/RDPAgent.app/Contents/MacOS/rdp-agent status`）；`bin/rdp-agent` 是另一个 TCC 身份。
6. **日志与诊断**：App 日志在数据目录 `logs/{app,worker,agent}.log`（启动时 >32 MiB 轮转）；手工形态在 `.runtime/`。`event=snake_case k=v` 单行格式。`WLOG_LEVEL=DEBUG`/`RDP_TRANSPORT_DUMP` 只在隔离测试短时开启。
7. **不做破坏性清理**：不要为了“整理仓库”删除 `.deps/`、`.runtime/`、`bin/`、`dist/`、`.worktrees/` 或任何回滚快照；不要杀不认识的进程。
8. **凭据与隐私**：不读取/打印/复制 `sam`、私钥、证书、`config.json` 内容或剪贴板内容到对话/日志/提交；需要检查权限只看 `stat`。屏幕截图仅用于临时诊断并立即删除。

## 7. 代码约定

**Go**：无第三方依赖（stdlib only）；包/导出符号注释与错误信息用英文，文档用中文；错误用 `%w` 包装；不要 panic 穿过 cgo 边界；回调中不做长阻塞，大帧/高带宽路径留在 C；配置解析保持 fail-closed（未知字段拒绝、绝对路径、权限不放宽）。

**C / cgo**：FreeRDP 事件循环固定在自己的原生线程；**最多 4 个 peer pthread**；每个 peer 独占 context/settings/callback 状态；C 侧**永不保存 Go 指针**；回调不阻塞不 panic；释放顺序遵循 `native/freerdp/README.md`；所有外部输入（RDP PDU、Agent IPC）做边界/长度/路径校验。Worker **没有优雅退出**：SIGTERM/崩溃不清理 socket，新增资源要能被下次启动清理。

**日志是事实上的测试 API**：`event=`/`reason=` 被 Python 测试用子串匹配，**只允许追加字段，不要重命名既有事件/原因词**；日志不得包含凭据、剪贴板内容、完整用户路径、屏幕内容。

**Swift**：纯逻辑放 `MacAgentCore`（可测、不依赖 AppKit/SCStream）；平台 API/CLI 放 `rdp-agent/main.swift`。新增/删除 MacAgentCore 源文件必须同步 `Makefile` 的 `agent-check` 清单以及 `scripts/test-agent-ipc-wire.py` 的 `CORE_FILES` 子集，否则静默漏测或链接失败。`Package.swift` 无 testTarget，测试是 plain precondition 单可执行。共享可变状态用 `NSLock` + `@unchecked Sendable`；socket 写串行化。Agent 接收线程对单条坏消息/未知类型要容错（只记日志、必要时 releaseAll）；socket EOF/不可恢复错误才 `exit(1)` 交给 launchd。**CLT-only 工具链没有 SwiftUI 宏插件**：禁止 `@State`/`@FocusState`/`#Preview`/`@AppStorage` 等宏，用 `ObservableObject`/`@Published`/`@StateObject`/`@Binding` 或 AppKit；不要设 `DEVELOPER_DIR` 绕过。

**Python**：`#!/usr/bin/env python3`、标准库、`unittest` + `argparse`；用 `ROOT = Path(__file__).resolve().parents[1]` 定位仓库根；测试必须隔离（临时目录/随机端口/临时证书/随机密码）并清理；破坏性操作必须显式参数。部分脚本（`test-protocol.py`、`benchmark-fps.py`）硬编码 Apple Silicon Homebrew 的 `/opt/homebrew/opt/openssl@3/bin/openssl`（`dev-init.py` 用 `brew --prefix`，`disp-diagnose.py` 有 `shutil.which` 兜底）；其它环境需改这两个脚本的路径。图标生成脚本 `scripts/generate-app-icon.py` 额外需要 Pillow，属可选开发依赖，不是构建/运行依赖。

**契约变更**：RDPA v1 的权威实现是 Swift + C；Go `internal/agentipc` 只覆盖旧类型且未被生产代码 import——**只改 Go 不会生效**。新增/修改消息类型时同步：C 解析器、Swift enum/codec、Python fake agent/测试、绑定契约文档（`docs/DESIGN-*`），并更新协议测试。保持前向兼容（未知类型忽略并限频日志），但文件剪贴板属硬匹配对。修改 generation/frameID、tile 尺寸、fit-with-bars、鼠标坐标域等契约必须同步三处实现（C/Swift/Python）并在 `docs/VERIFICATION-*` 记录证据。

## 8. 常见陷阱（按症状查）

> 先查本表；若症状与 §8.1「历史已修问题」一致，先确认是否为版本回归，不要重新设计。

| 症状 | 可能原因 | 做法 |
| --- | --- | --- |
| Worker 在跑但 live 会话被拒（`reason=no_frame`），日志无 `event=agent_ipc_listening` | 上次崩溃/被杀残留 socket，C 侧静默放弃监听 | 确认 Worker 已退出后 `rm -f` 旧 socket 再启动 |
| App 被 SIGKILL/崩溃后 `rdp-worker` 仍在监听 | 旧版本没有父进程看门狗；或手工/launchd 形态本就不带 `RDP_WORKER_MANAGED_BY_APP` | 当前 App 形态的 Worker 会在 `getppid()==1` 后记录 `event=worker_parent_exited` 并退出（`address:auto` 先停子进程）；残留进程按 PID/配置路径确认后清理，不要盲杀 |
| `address:auto` 子进程重启后 Agent 连不上（`reason=no_frame`） | 上一个子进程崩溃/被 SIGTERM 后 socket 仍在，C listener 静默放弃 | 当前 supervisor 在每次启动子进程前 unlink socket；确认版本并查 `event=lan_socket_remove_failed` |
| Worker 启动即退出（`Agent IPC socket requires an absolute path in an owned private directory`） | socket 路径非绝对、≥104 字节，或父目录非当前 UID/0700 | 用私有目录的绝对短路径 |
| 有画面但帧不更新 / 新 Agent 无帧 | generation/frameID 被判 stale | generation 非递减、同 generation 内 frameID 递增；重启 Agent 时取更大 generation |
| Agent 采集不到帧 | 显示器休眠/离线（SCK 返回空 displays，Agent 报 `display index is not available` 后退出）、屏幕录制未授权、SCStream queueDepth=1 | 唤醒显示器后重启 Agent（LaunchAgent 形态用 kickstart）；用 app 身份查权限；queueDepth 2..8 |
| TCC 显示已授权但注入无效 | 辅助功能未授权（CGEvent 静默丢弃）或用了错误可执行文件身份 | 用 `RDPAgent.app` 内二进制查状态；授权后重启进程 |
| 授权后 launchd Agent 仍不启动（可选 LaunchAgent 形态） | 未授权时按设计 `exit(0)`，`KeepAlive{SuccessfulExit:false}` 视为成功 | `launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent` |
| 改了 Swift 但 live 行为没变 | 只跑了 `make agent-build`，而运行的是 `RDPAgent.app` 内二进制 | `make agent-app` 后重启/重启 App |
| RDP 画面左右有黑边（应 1:1） | 虚拟显示器未创建/被跳过；或客户端分辨率与桌面框不一致 | 看 Agent `virtual_display_ready/skipped` 与 Worker `event=peer_frame_layout`（应 `scaled=0 content=desktop`）；手工形态需 `RDP_AGENT_VIRTUAL_DISPLAY=1` |
| 断开/崩溃后 macOS 分辨率停在非原生值 | 虚拟显示器 teardown 未完成 | 让 Agent 正常恢复或重启 Agent；必要时 `rdp-agent set-display-mode <w> <h>` |
| 虚拟显示器激活时鼠标越往右下偏越大 | 输入仍用物理屏 bounds 换算虚拟屏像素 | 更新到含 `InputDisplayTargetResolver` 的版本；看 `event=input_target_fallback` |
| macOS→Windows 文本粘贴偶尔失败 | Worker 未在每次本地剪贴板变化时发 `CB_FORMAT_LIST` | 确认 `event=clipboard_local_advertised`；保持每次变化都发 |
| 文件剪贴板粘贴失败 | 客户端拒绝、TCC 受保护目录、路径/大小超限 | 看 `clipboard_file_rejected reason=`；受保护目录给完全磁盘访问 |
| 剪贴板方向逻辑混乱 | 文本与文件的方向编号语义相反 | 按 wire 契约实现，不要“统一” |
| Windows 拖动窗口分辨率不跟随 | 客户端不发 DISP monitor layout（客户端限制） | 重连生效；读 DIAGNOSIS-2026-11-08-disp-window-resize；不要伪造 PDU |
| `go test` 全 `(cached)` | 未加 `-count=1` | 用 `go test -race -count=1 ./...` |
| 协议测试无法 listen / openssl 找不到 | 沙箱不允许 loopback，或脚本硬编码 Homebrew 路径 | 换允许 loopback 的环境；改脚本路径而不是放宽断言 |
| 改了 `internal/agentipc` 却不生效 | 该包未被生产代码 import | 改 `native.c` + Swift `AgentIPCMessage.swift` + 测试 |
| Worker 启动成功但首个连接失败（`peer_configure_failed`） | 证书/key 只在连接时加载 | 用 openssl 校验 cert/key 与权限 |
| 同一端口行为怪异/连不上 | 两套形态同时运行（App + 手工 worker/旧 LaunchAgent） | 只保留一套；旧的先卸载 |

### 8.1 历史已修问题（勿重复调查）

| 曾经的现象 | 根因（已修） | 复现时先做什么 |
| --- | --- | --- |
| macOS 26 上 Worker 一启动即 SIGSEGV（`PC=0`，栈 `freerdp_listener_open → CreateEventA → winpr_event_init`） | 早期包用 macOS 27 SDK 让 WinPR 弱导入 `_pipe2`，而 macOS 26 的 libSystem 不导出该符号 → weak-import 槽为 NULL 后被调用；**与 minos、TCC 都无关** | 确认走当前 `make deps`（显式 SDK + `-DWINPR_HAVE_PIPE2=OFF` 已内置）；**勿改 FreeRDP 源码**；`nm -u` 应无 `_pipe2`；`make test-freerdp-sdk-selection` 守护 |
| 目标机报 “built for macOS 27.0 newer …” | 包内 helper/dylib 的 minos 未归一化（App 主程序本来已是 14.0） | `make deps` + `make app-dmg`（Go/cgo `-mmacosx-version-min=14.0`，打包期 `vtool` 把第三方 dylib 归一化到 14.0）；审计包内全部 Mach-O 为 `minos 14.0` |
| 目标机保存 RDP 凭据/连接报 “no md4 support available” | OpenSSL 3 把 MD4/RC4 移入 legacy provider；其模块路径编译自构建机 Homebrew，目标机没装 Homebrew 就加载不到，NT 哈希算不出 | 当前构建默认 `WITH_INTERNAL_MD4/RC4=ON`；日志里 `OpenSSL LEGACY provider failed to load` 属无害提示；用 `OPENSSL_MODULES=/tmp/nonexistent rdpctl hash-stdin` 验证 |
| Windows 客户端连接被拒/错误 0x204 | DRDYNVC 在 PostConnect 之前自动打开，客户端把重定向包丢弃 | 已改为 PostConnect 后打开；复现先查动态通道回归 |
| 第二次连接报 0x904 / 卡死 peer 永久占用租约 | 单连接租约曾是裸 boolean，坏 peer 不释放 | 已改为 token + 1 s 心跳 + 30 s stale 接管 + `Release(token)` 归属校验；复现查租约路径 |
| 客户端最小化即断会话 | 服务端把客户端的 `SuppressOutput` PDU 又回显给客户端（方向非法） | 已修（记录 `client_output_suppressed`，抑制期不发帧、恢复时强制整帧）；不要重新引入回显 |
| 画面冻结 + 重连黑屏，日志见 `agent_ipc_write_timeout` | Agent 输入接收线程被单条异常消息杀死后，Worker 阻塞写满 socket 并持 `agent_mutex`，卡死绘图 peer | 已修（逐条消息 `do/catch`、`SO_SNDTIMEO` 500 ms、输入 best-effort 丢弃）；复现先查是否回归，不要重新设计 IPC |
| 快速断开后立即重连失败（finalization 阶段，“N bytes not processed”） | FreeRDP **fastpath** 输入回调缺少 slow-path 的 state 守卫，返回 `FALSE` 被当作致命接收错误 | 已修（finalization 窗口内忽略早输入并返回 `TRUE`，`event=early_input_dropped`）；复现查回调返回值 |
| 显示器休眠后 RDP 无画面、Agent 退出 | ScreenCaptureKit 在显示器休眠时返回空 displays（与虚拟显示器无关） | 唤醒显示器并重启 Agent；**不要改虚拟显示器逻辑** |
| 日志显示协商/TLS 完成但 `ready=0`、`last_error=0x00000000` 后连接消失 | 客户端在证书或密码对话框点了取消 | 不是服务端故障；让客户端完成证书信任/输入密码；确认是否出现 `event=authorized` |
| 怀疑帧率回归 / “60 fps 未达标” | 60 fps 只是配置目标；服务端帧计数 ≠ 客户端渲染 FPS；早期日志的 timing（`conversion_ms` 虚高）不可用 | 按 §1 性能口径与 benchmark 脚本复测；真实 FPS 必须在客户端用可见动画测量 |

## 9. 测试矩阵

| 命令 | 覆盖 | 前置 / 说明 |
| --- | --- | --- |
| `make test` / `go test -race -count=1 ./...` | Go：agentipc 编解码、auth gate、config 校验、worker(cgo) | 需 `.deps/install` |
| `make check` | 上面 + C gfx 策略 + AVC 编码器 + `go vet` | 默认必过集合，但不含 protocol/bundle |
| `make test-protocol` / `python3 scripts/test-protocol.py` | 35 例 loopback E2E：NLA/凭据/租约/超时、位图/增量、尺寸协商与 DISP、鼠标坐标、文本+文件剪贴板、Agent IPC、显示恢复 | 需 `bin/` 三个产物、本机 TCP listen；约 90–100 s；AVC420 默认 skip |
| `make agent-check` | Swift 纯逻辑（IPC、delta、几何/坐标、键盘状态机、剪贴板、虚拟显示器、点击） | 24 核心 + 6 测试文件；无 GUI/TCC |
| `make test-agent-ipc-wire` / `make test-agent-launchd` / `python3 scripts/test-clipboard-handshake.py` | 真实 Unix socket IPC / LaunchAgent plist / C 剪贴板 helper | 5 / 4 / 6 例 |
| `make test-virtual-display` | 虚拟 16:9 显示器 6 例 | **会短暂改真实显示排列** |
| `make test-app` / `test-app-bundle` | App 核心契约 / DMG bundle 校验 | 隔离临时目录；DMG 只读挂载 |
| `RDPServer --status` / `--self-test`（`RDPSERVER_SELFTEST_START=1`） | App 无头自检（JSON + exit code） | 不创建数据目录/不起服务（SELFTEST_START 除外） |
| `python3 scripts/benchmark-fps.py` / `benchmark-live-agent.py` | 服务端/整链帧率基准 | 自建隔离 Worker；**不是**客户端渲染 FPS |
| `make test-freerdp-sdk-selection` / `test-freerdp-no-pipe2` | macOS 26/27 可加载性回归 | 纯配置/产物检查 |

**不能自动化、必须人工确认的**：Windows 客户端真实画面/输入/剪贴板手感、DISP 客户端行为、TCC 授权持久性、Gatekeeper/干净机器安装、LaunchAgent 重启、断线重连体验。写结论时明确区分 **本机实测 / 源码推断 / 未验证**，不要把 loopback 测试当成真机验收。

## 10. 文档索引

| 文档 | 用途 |
| --- | --- |
| [README.md](README.md) | 人类上手：构建、安装 DMG、连接 Windows 客户端 |
| [docs/STATUS-2026-11-08.md](docs/STATUS-2026-11-08.md) | **当前状态/范围/测试基线/已知限制（权威入口）** |
| [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) | 版本矩阵、构建顺序/产物、第三方许可证、可复现性边界 |
| [PLAN.md](PLAN.md) | 早期规划记录（已被当前实现取代，不是当前任务清单） |
| [docs/README.md](docs/README.md) | docs 目录索引（DESIGN/DIAGNOSIS/VERIFICATION/archive） |
| `docs/DESIGN-*.md` | 实现契约（分辨率/鼠标、文件剪贴板、虚拟显示器、菜单栏 App/UI/打包） |
| `docs/DIAGNOSIS-*.md` | 现场问题根因与验证（DISP 客户端限制、键盘 Fn、虚拟显示器鼠标偏移） |
| `docs/VERIFICATION-*.md` | 验收/构建验证证据 |
| `docs/archive/` | 仅历史追溯（命令、路径、数字均已过期，勿按其中操作） |
| [native/freerdp/README.md](native/freerdp/README.md) | cgo 所有权/线程/安全约束 |

- **不新增交接类文档**：当前状态以 STATUS 与代码为准，历史证据写入 VERIFICATION/DIAGNOSIS；早期阶段记录保留为历史材料。
- 文档命名：`docs/CATEGORY-YYYY-MM-DD[-slug].md`，`CATEGORY` ∈ `DESIGN`/`DIAGNOSIS`/`PERFORMANCE`/`VERIFICATION`/`STATUS`；阶段验收在 `docs/validation/`，被取代的记录放 `docs/archive/`。文档是历史证据：**新增而不是重写既有证据**，用相对链接互引。
- 改动行为/命令/范围时同步更新：STATUS（状态）、对应 DESIGN/VERIFICATION（契约/证据）、README（用户可见步骤）、AGENTS（纪律与陷阱）、DEPENDENCIES（依赖/版本）。

## 11. 提交与协作规范

- 提交主题：`Area: 摘要` 或祈使句（`Worker:`/`Agent:`/`Clipboard:`/`Docs:`/`Tests/tooling:`/`Fix ...`）；正文写根因/改动/证据，必要时加 `Verified:` 行。提交前测试要绿。
- 改动保持最小、单一目的：不重排无关代码、不批量改注释、不顺手“整理”无关文件；先看 `git status`/`git log`。
- **不提交**：构建产物（`bin/`、`dist/`、`.deps/`、`native/macos/.build/`）、私有状态（`.runtime/`、日志、回滚快照、socket）、凭据（SAM/私钥/证书/密码）、`.DS_Store`、临时 worktree。
- 开源合规：保留 `LICENSE`、`NOTICE`、`THIRD-PARTY-NOTICES.md` 与依赖许可证声明；不要移除 FreeRDP/OpenSSL/json-c/Go runtime 的归属信息（见 DEPENDENCIES §8）。打包 DMG 会把三份许可证复制到 `Contents/Resources/Licenses/`。
- 贡献入口：开 Issue/PR 描述动机、改动与验证方式；畸形提交（force-push 公共分支、改写已发布历史）不接受。

## 12. AI 代理开工清单

1. **先读**：本文件 → `docs/STATUS-2026-11-08.md` → 相关 `docs/DESIGN-*`/`DIAGNOSIS-*`；再用 `git log --oneline -20`、`git status` 确认分支与未提交改动。
2. **只读勘察**：`go version`、`swift --version`、`ls .deps/install`、`pgrep -fl 'RDPServer|rdp-worker|rdp-agent'`；确认是否已有服务在跑、用户在用哪套形态。**不要重启/停止任何正在服务的进程。**
3. **确认范围**：需求与 `docs/STATUS` 的范围一致；`PLAN.md` 仅作历史背景。跨范围能力（远程登录、多用户、音频等）先问，不要自行实现。
4. **隔离实验**：测试用临时目录 + 随机 loopback 端口 + 临时 config/SAM/证书/socket；不要读写真实数据目录，不要复用真实 socket，不要跑会覆盖 `bin/` 的构建。
5. **TDD**：bugfix 先写能失败的回归测试（RED）再修；改协议/安全/坐标/剪贴板路径必须补 E2E 断言，并同步 C/Swift/Python 三处实现。
6. **改完验证**：按改动范围跑 §9 的套件；涉及 UI/打包跑 `make test-app`/`app-dmg && test-app-bundle`；最后跑 `make check`。把“跑了什么/没跑什么/为何”写进报告。
7. **收尾**：更新受影响文档（STATUS/DESIGN/README/AGENTS/DEPENDENCIES）；提交前检查 `git diff` 无凭据/日志/产物；不确定的事实标注“未验证”。
8. **禁止**：读取/打印秘密；重启或杀线上进程；修改 `.runtime/`、`.deps/`、`bin/`、`dist/`、`native/macos/.build/`、`.worktrees/`；绕过 TCC/SIP；为“让测试过”放宽安全断言。
