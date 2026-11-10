# 菜单栏 App UI 设计（RDPServer 可执行）— 2026-11-08

> **2026-11-09 变更**：高级区的「释放卡住按键」按钮及其禁用/提示逻辑已移除（键盘根因修复后不再需要）。
> 本文中该按钮相关的布局/交互/验证描述保留为当时的 UI 设计记录；当前界面不再包含该按钮。

> **状态**：已实现并本机构建通过（`swift build -c release --package-path native/macos` 全绿，
> 含 RDPServerCore 与 RDPServer 产品）。菜单栏图标 / 弹窗 / 账号编辑 / CLI 均已落地；
> 真实鼠标点击与键盘输入路径为**未自动化验证**（见 §8）。
>
> - 关联：[AGENTS.md](../AGENTS.md)（运维红线/代码约定）、
>   [docs/STATUS-2026-11-08.md](STATUS-2026-11-08.md)（当前运行态）、
>   [docs/DESIGN-2026-11-08-menu-bar-app.md](DESIGN-2026-11-08-menu-bar-app.md)（RDPServerCore 契约，app-core 所有）。
> - 代码：`native/macos/Sources/RDPServer/`（可执行）、`native/macos/Sources/RDPServerCore/`（核心库，只读依赖）。
> - 打包：`dist/RDPServer.app`（packaging 负责，见 `docs/DESIGN-2026-11-08-app-packaging.md`）。

---

## 1. 目标与范围

用户请求（原文）：状态栏图标，点击后弹出小窗；小窗显示程序开关状态、当前 IP 监听地址、
权限检测按钮（缺失权限时点击可弹出权限申请窗口）、可自定义远程 RDP 用户名和密码。

本可执行负责：

- `NSStatusItem` 菜单栏图标（模板图，随服务状态变化）+ `NSPopover` 弹窗（宽 360 pt，高度自适应）；
- 服务开关（启用/停止）、监听地址展示与复制、桌面采集/权限状态、账号编辑；
- 局域网访问开关（主界面显眼位置）、端口、释放卡住按键、打开日志、退出（高级区）；
- 无头 CLI（`--status` / `--self-test` / `--version` / `--help`），供 DMG 验证脚本与测试驱动；
- 不实现：DMG/签名/安装（packaging）、Worker/Agent 生命周期与配置/凭据/权限探测（RDPServerCore）、
  远程登录/解锁/多用户（产品边界，见 PLAN.md §1）。

## 2. 架构

```
RDPServer（本可执行，SwiftUI + AppKit）
  ├─ main.swift           @main：先 CLI 分发，再 NSApplication(.accessory) + AppDelegate
  ├─ MenuBarController    NSStatusItem + NSPopover + NSHostingController(PopoverView)
  ├─ AppModel             @MainActor ObservableObject：轮询、动作、瞬态 UI 状态（单一状态源）
  ├─ LiveCoreBridge  ───► RDPServerCore.ServerManager（唯一 import 核心的文件）
  ├─ MockCoreBridge / BrokenCoreBridge   开发模拟 / 核心初始化失败兜底
  ├─ PopoverView / AdvancedSection / CredentialsEditorView   视图（只依赖 AppSnapshot 镜像类型）
  └─ DevPreview           离屏渲染 PNG（仅开发，见 §7）
```

- 视图只认识 `AppSnapshot / UIServiceState / UIAgentState / UIPermissions`（UI 镜像类型），
  core 类型名称变化只影响 `LiveCoreBridge.swift`。
- 所有阻塞操作（进程/文件/子进程探测）在 core 内部离主线程；UI 侧 `await`，不阻塞主线程。
- **本机工具链只有 Command Line Tools（无 Xcode）**：`@State`/`@FocusState`/`#Preview` 等
  SwiftUI **宏**不可用（缺 `SwiftUIMacros` 插件）。因此局部 UI 状态一律放在 `AppModel`
  （`@Published`），视图只用 `@ObservedObject`/`Binding(get:set:)`（非宏）。
- 部署目标 macOS 14+，只用 Swift 标准库 + Apple 框架，无第三方依赖。

**默认/发布路径 = 真实 core（唯一）**：`AppBootstrap.makeModel` 只有在
`RDPSERVER_UI_MOCK=1` 时才构造 `MockCoreBridge`；否则一律构造 `LiveCoreBridge`
（真实 `ServerManager`），失败时退到 `BrokenCoreBridge`（只显示初始化错误，绝不伪造服务状态）。
`DevPreview` 仅由 `RDPSERVER_UI_SNAPSHOT` 触发、`DevSmoke` 仅由 `RDPSERVER_UI_SMOKE` 触发。
这些环境变量在 Finder/launchd 启动的打包 App 中不存在，因此 DMG 里恒为真实 core，
且不会自动弹窗、自动启动服务或自动请求 TCC。离屏 PNG 仅由开发者显式指定路径时生成。

## 3. 弹窗布局（360 pt 宽）

```
┌────────────────────────────────────────────┐
│ [display] RDP 远程桌面             [启用/停止] │  ← 状态点 + 未启用/启动中/运行中/错误
│           ● 运行中                            │
├────────────────────────────────────────────┤
│ (错误横幅: 最后错误 + 打开日志)                │  ← 有 lastError 时出现，非模态
│ (重启横幅: 设置已保存，重启服务后生效 [立即重启])│  ← core needsRestart=true 时
├────────────────────────────────────────────┤
│ 连接地址                                     │
│ 192.0.2.10:3389                   [复制]     │  ← 等宽大字号，可选中
│ 用 Windows App 或 mstsc 连接此地址，用户名     │
│ MACRDP\user。                                │
│ ────────────────────────────────────────── │
│ 允许局域网访问 [开关]          仅限可信私有网络 │  ← 主界面显眼位置（产品主要玩法）
│ 同一局域网 / Tailscale 内的设备可访问          │
│ 192.0.2.10:3389。仅限可信私有网络，不要暴露公网 │
├────────────────────────────────────────────┤
│ 桌面采集                          ● 正在采集  │
│ 权限正常 · pid/generation 示例                │
├────────────────────────────────────────────┤
│ 权限                                         │
│ ✓ 屏幕录制                              已授权 │
│ ✓ 辅助功能                              已授权 │
│ i 完全磁盘访问                            可选 │  ← 可选行；core 未暴露检测，只给设置链接
│   打开系统设置                                │
│ 首次授权会为 RDPAgent 弹出系统权限窗口；授权后   │
│ 需重启采集才会生效。完全磁盘访问为可选项：...     │
├────────────────────────────────────────────┤
│ 账号                                         │
│ MACRDP\user              修改用户名和密码      │
├────────────────────────────────────────────┤
│ > 高级  (端口 1024–65535 / 释放卡住按键 /       │
│          打开日志 / 退出 / 旧 LaunchAgent 提示) │
└────────────────────────────────────────────┘
```

- 关闭局域网时提示：**当前仅本机可连；Windows 客户端连接请打开「局域网访问」。**
- 打开局域网时橙字提示：**仅限可信私有网络，不要暴露到公网**（附当前地址）。
- 未授权权限行显示 `请求权限` + `打开系统设置`；已授权行只显示 `已授权`（减少噪音）。
- 未配置账号（首启）时账号显示 `MACRDP\（未设置）`，点主按钮会打开账号编辑并提示
  “请先设置 RDP 用户名和密码”，不直接报错。
- 弹窗高度随内容（错误横幅/高级展开/账号编辑）自适应；上限 720 pt。

## 4. 账号编辑（弹窗内页面，替代 NSWindow sheet）

`CredentialSheet` 需求以「弹窗内整页」实现：SwiftUI `.sheet` 在 `NSPopover` 内不可靠
（可能脱离定位/尺寸异常），因此点击「修改用户名和密码」后把弹窗内容切换为编辑页：

- 用户名（TextField，预填当前账号）、密码、确认密码（SecureField）；
- 行内校验：用户名 1–64 位小写字母/数字 `.` `_` `-`；密码非空且 ≤4095 UTF-8 字节；两次一致；
- **运行中保存**：显示橙色警告“保存后服务会重启，当前 RDP 连接会断开”，并勾选
  “我了解，保存后重启服务”后才可保存（保存 → core 写 SAM/config → UI 调 restart()）；
- 明文密码只存在 `AppModel.credentialPassword`（编辑页打开期间），保存/取消立即清空，
  不写日志、不持久化、不显示；core 负责 `rdpctl hash-stdin` 生成 NT 哈希写 SAM。

## 5. 状态与动作映射

| UI 元素 | 数据来源（core） | 动作 |
| --- | --- | --- |
| 状态点/标题 | `ServerSnapshot.state` | — |
| 主按钮 启用/停止 | 同上；`configured` 决定是否先引导账号编辑 | `setEnabled(!running)` |
| 连接地址 | `address`（运行中）否则 `listenHost:port` | 复制到剪贴板 |
| 局域网开关 | `allowLAN` | `setAddressMode(.lan/.loopback)`（运行中保存后提示重启） |
| 桌面采集 | `agentState` + `agentDetail` + `permissions` | — |
| 权限行 | `PermissionSnapshot.screenRecording/accessibility`（`isAvailable=false` 时显示“权限状态未知”） | `requestPermissions()`（RDPAgent 身份 TCC）/ 打开系统设置 URL |
| 账号 | `account/principal` | 账号编辑页 |
| 端口 | `port` | `setPort(1024–65535)` |
| 释放卡住按键 | `supportsReleaseStuckKeys()`（`false` 时按钮禁用）→ `releaseStuckKeys()`（SIGUSR1，不中断画面） | 结果内联显示 |
| 打开日志 | `logsDirectory` | Finder 打开 |
| 重启横幅 | `needsRestart` | `restart()` |
| 退出 | — | `shutdown()` → `NSApp.terminate` |

- 轮询：弹窗打开 1 s、关闭 2 s（`setPopoverVisible` 切换）；`refresh()` 由 core 异步执行。
- **释放卡住按键的能力门禁**：core `ServerManager.supportsReleaseStuckKeys()` 探测已安装
  Agent 是否含 SIGUSR1 handler（对旧 Agent 发 SIGUSR1 会直接杀进程）。UI 在 `false` 时禁用按钮
  （`.help` 提示“当前 Agent 版本不支持（需 Worker/Agent 成对部署）”，说明文字变橙色），
  并在 `AppModel.releaseStuckKeys()` 里再兜底拒绝。能力探测在 `Task.detached` 里执行
  （首次可能读取 Agent 二进制），随轮询刷新。
- 菜单栏图标（模板图）：未启用=display 轮廓；启动中/停止中=轮廓+空心点；运行中=轮廓+实心点；
  错误=display.trianglebadge.exclamationmark。图标的 App 状态颜色由系统自动着色。
- SIGINT/SIGTERM（终端开发运行）走优雅 `shutdown()` 后退出，避免遗留 worker/agent 子进程。

## 6. CLI 契约（无头）

CLI 由 **RDPServerCore.RDPServerCLI** 实现并在 `main.swift` 里**先于 AppKit** 分发；
RDPServer 只负责在返回 nil 时启动 GUI。packaging 的 DMG 验证脚本可依赖：

```sh
RDPServer --status   [--data-dir PATH]   # 单个 JSON 对象，stdout；成功报告 exit 0
RDPServer --self-test[--data-dir PATH]   # 单个 JSON 对象，stdout；全部检查通过 exit 0
RDPServer --version                      # "RDPServer 0.2.3"，exit 0
RDPServer --help                         # 用法，exit 0
# 无上述 flag → 菜单栏 GUI
```

- `--data-dir` 必须是绝对路径；也接受 `--data-dir=PATH`；环境变量 `RDPSERVER_DATA_DIR`、
  `RDPSERVER_HELPERS_DIR`。默认数据目录 `~/Library/Application Support/RDPServer`。
- `--status` 不启动 worker/agent、不创建/修改数据目录、不请求 TCC、不读 `.runtime`；
  `--self-test` 只在传入的隔离目录里造配置/证书，`RDPSERVER_SELFTEST_START=1` 才启动服务（默认不启动）。
- 不打印密码/NT 哈希；`account` 只输出裸用户名（非凭证）。
- 示例（本机实测，全新临时目录）：

```json
{"ok":true,"app_version":"0.2.3","data_directory":"/tmp/x","state":"disabled","configured":false,
 "enabled":false,"address":null,"listen_host":"127.0.0.1","port":3389,"allow_lan":false,
 "account":null,"principal":null,
 "permissions":{"screen_recording":true,"accessibility":true},
 "agent":{"state":"waiting","detail":null},"worker":{"running":false,"pid":null},
 "last_error":null,"logs_directory":"/tmp/x/logs","error":null}
```

```json
{"ok":true,"checks":[{"name":"helpers.rdp-worker","ok":true,"detail":"..."}, ...],
 "data_directory":"/tmp/x","started_service":false,"error":null}
```

> 注：JSON 字段与退出码由 core 的 `StatusReport`/`SelfTestReport` 决定；
> 字段集合与 packaging 验证脚本已对齐（`app_version`、`worker.running`、`state`、`ok` 等）。

## 7. 构建、运行与 UI 验证（开发）

```sh
# 构建（默认工具链；不覆盖 bin/，不影响正在服务的进程）
swift build -c release --package-path native/macos            # 全包（含 rdp-agent）
swift build -c release --package-path native/macos --target RDPServer

# 正常开发运行：真实 core + 隔离数据目录（不启动服务，不读现有 .runtime）
RDPSERVER_DATA_DIR=/tmp/rdpserver-dev native/macos/.build/release/RDPServer
# 菜单栏出现 display 图标，点击弹出弹窗；首次启动未配置时主按钮引导设置账号。

# 纯 UI 迭代（模拟桥，不触碰真实服务）：RDPSERVER_UI_MOCK=1 及可选项
RDPSERVER_UI_MOCK=1 RDPSERVER_UI_MOCK_STATE=running RDPSERVER_UI_MOCK_PERMISSIONS=granted \
  RDPSERVER_OPEN_POPOVER=1 native/macos/.build/release/RDPServer
#   RDPSERVER_UI_MOCK_STATE=running|error|(缺省 disabled)
#   RDPSERVER_UI_MOCK_PERMISSIONS=granted
#   RDPSERVER_UI_MOCK_LEGACY_AGENT=1  模拟旧 Agent（「释放卡住按键」按钮禁用）
#   RDPSERVER_UI_SNAPSHOT_ADVANCED=1  离屏快照时展开「高级」区

# 启动后自动展开一次弹窗（等价于点击状态栏图标；dev/test 用，默认关闭）
RDPSERVER_DATA_DIR=/tmp/rdpserver-dev RDPSERVER_OPEN_POPOVER=1 native/macos/.build/release/RDPServer
RDPSERVER_DATA_DIR=/tmp/rdpserver-dev native/macos/.build/release/RDPServer --show-popover
#   RDPSERVER_OPEN_POPOVER=1（或 --show-popover）只影响首次展示，不改变服务状态；
#   RDPSERVER_UI_DEV_OPEN=1 保留为别名。无辅助功能权限时也可用于自动截图。

# 离屏渲染 PNG（开发者验证；无需屏幕录制权限、不采集桌面像素）
RDPSERVER_UI_MOCK=1 RDPSERVER_UI_SNAPSHOT=/tmp/ui.png native/macos/.build/release/RDPServer
RDPSERVER_UI_MOCK=1 RDPSERVER_UI_SNAPSHOT_VIEW=credentials RDPSERVER_UI_SNAPSHOT=/tmp/ui-cred.png ...
RDPSERVER_UI_MOCK=1 RDPSERVER_UI_SNAPSHOT_VIEW=icon RDPSERVER_UI_SNAPSHOT=/tmp/ui-icon.png ...

# 真实 core 的 UI 动作层无头冒烟（隔离数据目录 + 随机 loopback 端口；不碰现有 .runtime/3389）
RDPSERVER_UI_SMOKE=1 RDPSERVER_DATA_DIR=/tmp/rdpserver-smoke \
  RDPSERVER_SMOKE_ACCOUNT=smoketest RDPSERVER_SMOKE_PASSWORD='<random-test-password>' \
  native/macos/.build/release/RDPServer
# 依次执行：保存凭据（并清空明文）→ 改端口 → start（起 Worker+Agent）→ 权限探测
# → releaseStuckKeys（SIGUSR1）→ stop → shutdown；输出一个 JSON（ok + checks），exit 0/1。
# 仅开发/验证用；打包产物不会走到这条路径（需要显式环境变量）。
```

### 7.1 UI 生命周期日志（用于无辅助功能权限时确认 UI 真实存在）

- 文件：`<data>/logs/app.log`（与 core 的 AppLog 同文件/同格式
  `<epoch_ms> event=<snake_case> k=v`，0600，append-only）；同时写 stderr。
- 事件：
  - `event=menu_bar_ready state=<disabled|starting|running|stopping|error>`：状态项创建成功；
  - `event=popover_opened state=...` / `event=popover_closed state=...`：弹窗展示/关闭
    （同一事件 0.5 s 内去重，避免 transient 弹窗刷屏）。
- 不记录凭据、剪贴板内容、按键文本、绝对用户路径。只对 core 已创建的 logs 目录追加；
  mock 模式不会创建目录。
- 示例（真实 core，隔离数据目录）：

```
1794140643821 event=menu_bar_ready state=disabled
1794140645142 event=popover_opened state=disabled
```

- Mock / snapshot / auto-open 开关均为**开发专用环境变量**：Finder/launchd 启动的打包 App
  没有这些环境变量，因此发布路径始终是真实 core + 不自动弹窗、不自动启动服务、不自动请求 TCC。
- 截图验证：真实运行可用 `screencapture -x -o -l <window-id> file.png` 只截弹窗窗口；
  菜单栏图标用 `screencapture -x -R 0,0,<width>,32` 截顶栏。截图仅临时用于诊断，不提交。

## 8. 已验证 / 未验证

**本机已验证（2026-11-08）**

- `swift build -c release --package-path native/macos` 全包绿；`--target RDPServer` 绿。
- CLI 契约：`--version`/`--help`/`--status`/`--self-test`（含 `--data-dir` 与
  `--data-dir=` 及 `RDPSERVER_DATA_DIR`）全部 exit 0，stdout 为单个可解析 JSON；
  HOME 重定向后默认 `~/Library/Application Support/RDPServer` 未被创建；`--status` 后
  临时目录仍为空（不写数据）、无 worker 进程启动。
- 真实 GUI 运行（隔离 `RDPSERVER_DATA_DIR=/tmp/...`）：菜单栏出现模板图标，弹窗 360 pt
  内容 + 自适应高度（窗口约 386×569），状态点/按钮/权限行/账号/高级渲染正常。
- 弹窗窗口截图与顶栏截图（真实像素）确认：运行中图标带实心点；局域网开关打开时显示橙色安全提示；
  关闭时显示“当前仅本机可连…”。
- 四种图标（未启用/启动中/运行中/错误）模板图渲染可区分。
- 账号编辑页、错误横幅、needsRestart 横幅、采集中/采集异常/权限缺失等状态由离屏渲染确认。
- 未配置账号首启状态（`MACRDP\（未设置）`）由真实 core + 空临时目录确认。

- **真实 core 的 UI 动作层冒烟通过**（`RDPSERVER_UI_SMOKE=1`，隔离数据目录、随机 loopback
  端口，2026-11-08，耗时 0.8 s）：保存凭据→configured=true 且明文被清空；改端口生效；
  启用→state=running、address=127.0.0.1:23094、Worker/Agent 均在运行；
  权限探测 screen/accessibility=已授权；`释放卡住按键`→“已发送释放按键”（core 返回 released）；
  停止→disabled 且 Worker 退出；shutdown 后无遗留进程。
- **释放卡住按键能力门禁实测（两条分支）**：用 `RDPSERVER_HELPERS_DIR=dist/RDPServer.app/Contents/Helpers`
  （新 Agent，含 SIGUSR1 handler）跑真实 core 冒烟 → `supportsReleaseStuckKeys=true`、
  `release_stuck_keys` 成功，15 项全 PASS；用仓库 `bin/` 里旧的 Agent（2026-11-08 16:22，无 handler）
  → `false`、按钮禁用、AppModel 直接拒绝（core 也会返回 `notSupported`），不会给旧 Agent 发 SIGUSR1。
  mock `RDPSERVER_UI_MOCK_LEGACY_AGENT=1` 离屏快照确认禁用外观 + 橙色说明。
- `RDPSERVER_OPEN_POPOVER=1` 与 `--show-popover` 均实测可自动展开弹窗；
  `<data>/logs/app.log` 实测出现 `menu_bar_ready`、`popover_opened` 行（真实 core，隔离目录）。
- 截图证据仅用于当时验证（保存在本地临时目录，未入库）。

**未验证（需人工或有 GUI 的验收）**

- 鼠标真实点击启用/停止/修改账号/保存/权限请求按钮的完整交互（动作链路已用 `RDPSERVER_UI_SMOKE`
  从 AppModel→LiveCoreBridge→core 验证；但鼠标事件分发/焦点/点击状态栏图标的真实交互未自动化）；
  `关闭弹窗 → 重新打开`、文本输入焦点、SecureField 行为。
- 「请求权限」触发的 TCC 弹窗实际弹出（core 调 RDPAgent 身份；本机当前权限已授权，无法复现缺失场景）。
- 「释放卡住按键」对真实 Agent 的 SIGUSR1 效果（需要运行中的 Agent；核心逻辑属 app-core）。
- 打包后 `dist/RDPServer.app` 的 LSUIElement/Helper 路径/签名行为（packaging 负责，其验证脚本依赖本 CLI）。
- 多显示器/深色模式/放大字体等外观细节；弹窗超过 720 pt 时无滚动（当前内容最大约 620 pt）。

## 9. 已知限制与 TODO

1. **离屏快照里 Toggle 可能显示为关闭**（SwiftUI 开关动画在无窗口渲染第一帧的假象）；
   真实窗口渲染正确（已用窗口截图核对）。仅影响开发快照，不影响运行时。
2. 权限区「完全磁盘访问」无检测（core `PermissionSnapshot` 未暴露），只提供设置链接与说明，
   不伪造状态。若 core 以后提供检测，加一行映射即可。
3. 弹窗高度上限 720 pt 且无内部滚动；内容继续增长时需加 `ScrollView`（需同时改尺寸上报）。
4. 退出只在正常 UI 路径 await `shutdown()`；`applicationWillTerminate` 仅兜底说明。
   若进程被 `SIGKILL`，App 拉起的 Worker 通过 `RDP_WORKER_MANAGED_BY_APP` 看门狗
   发现父进程消失后自行退出（并停止 `address:auto` 监督的 FreeRDP 子进程），
   不依赖下次启动的残留清理；下次启动仍会 unlink 可能残留的 socket。
5. 账号编辑为弹窗内整页（非 NSWindow sheet），见 §4 原因；若未来弹窗改为独立窗口可换回 sheet。
6. 菜单栏图标状态目前只区分 4 种；如需“未配置”“缺少权限”等提示需扩展 `MenuBarIcon`。
