# macOS RDP Server 实施计划与 Session 交接

更新时间：2026-11-09（Asia/Shanghai）。**当前实现状态、可用范围与测试基线以
[docs/STATUS-2026-11-08.md](docs/STATUS-2026-11-08.md) 为准**；本文件的阶段/范围/边界仍然有效。

## 当前范围调整（2026-11-01）

首阶段范围已确认：只支持 Mac 用户先在本机完成登录，然后通过 RDP 控制当前用户桌面。
当前不要求从 RDP 登录 macOS、解锁已锁屏 Mac 或恢复 FileVault 启动。按此范围，P0-B
登录窗口桥接暂缓；不启用系统屏幕共享，不引入 VNC/RFB 依赖。若用户以后重新提出
重启后远程登录/解锁，再单独评估该能力。

当前 RDP 桌面仅在授权用户已登录且其桌面 Agent 就绪时可用。首阶段不接管其他用户，
也不承诺在锁屏状态下继续采集或远程解锁；不可用时应拒绝连接或清屏并断开，不得
回退显示其他用户桌面。

## 1. 项目目标与当前状态

使用 Go 作为主语言，在 macOS 上运行 RDP 服务端，使已在 Mac 本机登录的用户能通过 Microsoft Windows App 输入 IP 和账号密码控制当前桌面。

目标体验是尽量接近 Windows 连接 Windows，包括账号认证和桌面控制。重启后登录、
锁屏解锁目前不属于首阶段范围。

已确认的要求：

- 保留 Go 作为主语言，复用成熟 RDP 内核。
- 服务端必须实现账号认证。早期“不建设认证”的设想已撤回。
- 首阶段要求 Mac 用户先在本机登录；不要求 RDP 登录 macOS 或解锁锁屏设备。
- 内网直接通过 IP 连接；互联网流量由 Tailscale（或等效 VPN）保护。
- 不建设 RD Gateway、云端中继或自有公网穿透系统。
- 首先形成可落地方案，避免从零重写 RDP 协议。

当前仓库已有 P0-A/P0-C 原型：Go 主服务 + cgo FreeRDP Worker（3.32.2）+ Swift Agent。
真实 **Windows 11 `mstsc.exe`** 客户端已验收：NLA 连接、60fps 目标桌面采集、键鼠（含鼠标
边缘对齐与 Windows 方向滚轮）、文本剪贴板、**文件剪贴板双向**，以及**连接时按客户端桌面框
采集**（16:9 虚拟显示器 + 镜像物理屏，无黑边/无拉伸，断开自动恢复）。会话中拖动窗口实时改
分辨率仍不可用（客户端 mstsc 不发 DISP monitor layout，服务端 DISP 已实现并有诊断日志）。
LaunchAgent 常驻 Agent、单连接租约、无帧 fail-closed 均已具备。**2026-11-08 新增**：可拖拽
安装的菜单栏 App + DMG（状态栏控制/权限申请/自定义 RDP 用户名密码/局域网开关，App 管理
worker+agent）、键盘输入根因修复、macOS→Windows 文本剪贴板修复与鼠标双击修复（真机验收通过；
见 `docs/STATUS-2026-11-08.md`）。**2026-11-09 修复**：macOS 26/27 SDK 与 WinPR `pipe2` 构建兼容
（已在 macOS 26.5.1 确认启动成功）、虚拟显示器输入映射导致的鼠标左上偏移（已真机确认修复）。尚未实现：
远程登录/解锁、多用户并发、音频/文件系统重定向、多显示器排列快照、H.264/AVC420 生产路径、
Developer ID 稳定签名/公证/自动更新、限流与审计。完整状态与测试基线见
[docs/STATUS-2026-11-08.md](docs/STATUS-2026-11-08.md)；阶段验收历史见 `docs/validation/`。

### 证据边界

已完成开源仓库、部分源码、文档、发布说明和 Issue 调研。尚未验证：

- FreeRDP 在目标 Mac 上的完整服务端行为。
- 原生 Agent 帧缓冲和真实输入能否安全接入当前已登录用户的 RDP 桌面。
- 控制台用户身份/会话切换观察能否阻止跨用户画面泄露。
- FileVault、Tailscale 与目标硬件的实际启动行为。

“完全复刻 Windows 体验”是期望，不能作为已证明可实现的承诺。不得以虚拟显示器代替用户会话隔离，也不得把 PAM 验证成功当作 GUI 登录成功。

## 2. 推荐方案与默认边界

采用 Go 主服务 + FreeRDP Worker + macOS 原生桌面 Agent。

- FreeRDP 负责 RDP 协议、TLS、NLA/CredSSP、图形和虚拟通道。
- Go 负责配置、账号映射、授权、状态机、连接和进程生命周期、诊断。
- Swift/Objective-C 负责 ScreenCaptureKit、VideoToolbox、CGEvent、系统会话观测和权限检查。
- 首阶段只在用户本机登录后使用原生 Agent；登录窗口桥接不在当前范围。
- FreeRDP 放在独立进程中，防止原生崩溃终止 Go 主服务。

以下为方案默认值，尚不是逐项确认过的偏好；如有不同要求，需调整设计：

- 首版面向 Apple Silicon；以目标机器实际安装的 macOS 版本验收。FileVault SSH 恢复路径要求 Apple Silicon + macOS 26 或以上。
- 单活动 RDP 连接，绑定一个明确授权的 macOS 用户。
- 独立 RDP 账号密码，绑定 macOS UID + GeneratedUID。
- 当前原型使用独立 RDP 测试凭据；生产账号与 macOS 用户的映射/凭据策略仍需单独确认。
- 不提供并发独立 GUI 会话、不强制接管其他本地用户、不自动开启系统自动登录。
- 断线默认保留应用和用户会话；锁屏状态下不承诺可连接或继续采集，不实现远程解锁。
- 先采用物理显示器完成端到端验证；无头和私有虚拟显示 API 在后续阶段加入。
- 不默认安装 DriverKit HID 驱动，不关闭 SIP，不修改 TCC 数据库。

## 3. 组件、接口与数据流

### 3.1 Go 主服务 `rdpd`

以专用服务账号运行，通过系统 LaunchDaemon 在正常 macOS 启动后启动，独立于用户 GUI 登录。

职责：

- 管理服务配置、RDP 账号、目标用户映射、活动连接租约和会话状态。
- 管理 Worker；原型阶段由 Worker 自行监听单一配置端口，避免过早实现跨进程 socket 传递。
- 用户认证完成后执行桌面授权，未授权前不创建采集、输入或重定向后端。
- 协调登录后端与原生 Agent，记录连接、后端切换和恢复事件。
- 提供本地 CLI 管理入口，不新增公网管理 API。

### 3.2 RDP Worker `rdp-worker`

使用 Go + cgo + 薄 C 适配层调用 FreeRDP 服务端库，不直接包装 `freerdp-shadow-cli` 作为产品。

- 固定经过验证的 FreeRDP 稳定版本和构建选项；升级必须重新跑客户端矩阵。
- 调研时最新发布显示为 3.32.2，但实施时必须重新核对最新稳定版本及安全修复，不盲目固定旧版本或跟随 master。
- C 包装层管理 FreeRDP 对象、事件循环、线程和回调生命周期；明确所有权和释放规则。
- RDP 事件循环固定在相应原生线程；Go 回调不长期阻塞、不让 panic 穿过 C 边界。
- 禁止 C 长期保存未按 cgo 规则管理的 Go 指针。
- 高带宽路径留在原生侧；Go 处理描述符、输入事件和控制消息。
- 原型先验证位图桌面，再验证 VideoToolbox H.264 接入 EGFX；不宣称 FreeRDP 自动提供现成的 macOS 编码后端。

### 3.3 用户桌面 Agent `rdp-agent`

以登录用户身份运行，由 LaunchAgent 管理。当前阶段只绑定实际控制台用户；Swift/Objective-C 实现原生能力，Go 保留服务控制主体。

- ScreenCaptureKit 采集、VideoToolbox 编码、CGEvent 输入。
- 检查屏幕录制和辅助功能权限；缺失时返回明确状态，不能静默黑屏。
- 维护按键、鼠标按钮、坐标转换与显示器生命周期。
- 编码帧通过有界共享缓冲区传到 Worker 原生层；先允许有界拷贝正确实现，再按测量优化为共享内存。
- 不通过 JSON/base64 传输原始视频，不在 Go 堆中逐帧复制大图。
- 帧附带 session ID、generation、尺寸、时间戳；旧会话帧必须被拒绝。

### 3.4 特权 Helper

小型签名原生组件，仅提供受限的服务安装、系统会话核实及必要系统操作。

- 不以 root 解析全部 RDP 流量或执行日常桌面采集。
- 不暴露任意命令执行、任意路径写入或任意 UID 切换接口。
- 特权操作通过受校验的本地 IPC，核实对端身份和代码签名。

### 3.5 本地控制接口

控制通道使用 Unix domain socket；协议为带长度前缀的版本化消息，单消息大小设上限。原生 Helper 可用 XPC，提供小型桥接接口。

最低消息能力：

- `RegisterAgent`：UID、GeneratedUID、PID、generation、权限、显示器信息。
- `GetSessionState`：控制台身份、锁屏状态、Agent 状态。
- `AuthorizeConnection`：已认证 RDP principal、目标用户、connection ID。
- `AttachBackend` / `DetachBackend`：选择登录或原生桌面后端。
- `ReleaseInput`、`RequestKeyframe`、`Disconnect`。

不能信任进程自行提交的 UID。使用操作系统提供的对端凭据/审计信息及签名校验，核实其真实身份；Agent 注册不得据此获得其他用户权限。

## 4. 账号认证与授权

### 4.1 默认账号模型

RDP principal 绑定 macOS UID + GeneratedUID；显示用户名不能作为唯一授权依据。首版支持管理多个映射，但只有一个活动连接和一个实际控制桌面。

连接流程：

1. FreeRDP 完成 TLS + NLA/CredSSP。
2. 从认证结果取得 principal，执行账号启用状态、目标用户存在性及会话授权检查。
3. 原子获取单连接租约；第二个客户端默认拒绝接管。
4. 根据系统真实状态选择后端；授权完成之前不发送桌面内容。

RDP 域默认固定为 `MACRDP`。允许的客户端账号写法及规范化规则在认证原型中统一；未知域不得通过简单丢弃域名绕过账号匹配。

### 4.2 凭据存储

- 复用 FreeRDP/WinPR 的 NTLM 凭据支持，不自己实现 NTLM 或 CredSSP。
- 首选机器级受保护存储，必须能在用户尚未 GUI 登录时读取；不能依赖用户登录 Keychain。
- 在 P0 验证 `NtlmSamFile` 路径。若使用运行时 SAM 文件，仅包含必要 NT 哈希，置于专用服务账号私有目录，权限 0600，生命周期受控。
- NT 哈希视为密码等价秘密，不能仅因为“不是明文”降低保护。
- 不把密码放在命令行、日志、诊断包或普通配置文件。
- 密码更新作用于后续握手；禁用账号撤销活动连接并释放租约。
- 明确配置限速、失败锁定、握手超时和审计；这些能力不能默认认为由 FreeRDP 自动提供。

### 4.3 macOS 密码与登录

独立 RDP 密码只授权进入远程控制服务，不等于 macOS 密码。

- macOS 登录由系统登录界面处理；用户在远程画面中输入 Mac 密码。
- PAM/OpenDirectory 密码检查本身不创建 GUI 登录会话。
- 普通 macOS 密码检查接口不能直接替代 NLA 中的 NTLM 挑战应答。
- “直接使用 Mac 密码”和“一次输入自动进入桌面”留作后续能力，涉及凭据注册/更新及系统登录流程，不承诺已有公开 API 可完成。

## 5. 重启后登录与 FileVault

### 5.1 正常 macOS 登录窗口

候选路径：Go/RDP 系统服务先启动，通过本机 RFB 客户端接入 Apple 系统屏幕共享，将其登录画面转为 RDP 输出，将远程输入转为 RFB 输入。

首个实验必须证明：

- 指定 RFB 客户端、认证模式与目标 macOS 兼容。
- 无 GUI 用户登录时能看到并操作登录窗口，而不是只看到壁纸或黑屏。
- 锁屏、登录成功、注销等转换能被可靠处理。
- 本机连接可用，且系统屏幕共享端口不向其他网络开放。限制通过实际网络测试确认，不能假设系统服务支持配置为 loopback-only。
- 为桥接选择的机器凭据和认证方式不需要长期保存用户 Mac 密码；若做不到，重新评估该方案，不隐式增加系统密码保管。

RFB 桥接只是候选实现，不是已验证结果。先审查候选客户端库的许可证、Apple 认证兼容性和维护状态，再引入依赖。不要为原型重新实现完整 VNC 协议。

### 5.2 登录后交接

1. 观测实际控制台用户，核实与授权目标的 UID + GeneratedUID 一致。
2. 等待该用户 Agent 通过身份核验完成注册。
3. Agent 报告权限完备并输出有效首帧。
4. 暂停输入，释放登录后端的按键状态，清空旧帧和客户端旧画面。
5. 重置 RDP 图形表面，发送原生桌面关键帧，再允许输入。
6. 关闭登录后端，记录切换完成。

使用真实状态事件 + 定期核对，不使用固定 sleep 判断登录成功。无缝切换失败时，允许明确提示后重新连接；不得把此降级描述为已经达到无缝体验。

桥接无法验证通过时：暂停“重启后直接通过 RDP 登录”的承诺，记录失败证据；下一候选为专门的特权登录窗口后端。不得默认转向私有系统接口、DriverKit 或关闭 SIP，也不得用自动登录掩盖问题。

### 5.3 FileVault 阶段

- 磁盘未解锁时，不能依赖自建 RDP 或这台 Mac 上的 Tailscale 已启动。
- 计划重启可评估系统 authenticated restart，仅覆盖明确授权的一次重启，硬件与系统支持必须实测。
- Apple Silicon + macOS 26 或以上可评估 Apple 的 FileVault-over-SSH；需提前开启 Remote Login 和可用网络。
- 启动阶段 SSH 解锁后会发生连接中断，待系统服务恢复；磁盘解锁与 GUI 登录分开观测。
- 互联网恢复意外冷启动，需要独立可达路径，例如常开内网设备的 Tailscale 子网路由，再连接 Mac 的系统 SSH。
- 原有“不建设网关”的范围不因本计划自动改变。额外设备仅是可选恢复部署方案，在明确选择前不实施。
- 如果只有这一台 Mac、保留 FileVault、没有外部恢复路径或现场人员，就不能承诺所有意外冷启动都能远程恢复。

## 6. macOS 会话状态机

`FILEVAULT_LOCKED` 为外部恢复状态：服务自身可能尚不可用，不能声称能自行报告该状态。

正常系统启动后的主要状态：

| 状态 | 行为 |
| --- | --- |
| LOGIN_REQUIRED | 使用已通过验证的系统登录后端 |
| AGENT_STARTING | 显示状态画面，禁止桌面输入 |
| DESKTOP_READY | 使用原生 Agent |
| LOCKED | 立即停原生输入、丢弃旧帧、清空客户端画面；尝试系统解锁后端 |
| OTHER_USER_ACTIVE | 拒绝接管，不连接或显示其他用户桌面 |
| AGENT_UNAVAILABLE | 停止输入并清空画面，显示恢复状态，超时后断开 |

必须满足：

- 认证为 A 不得看到 B 的桌面；快速用户切换时立刻撤销旧后端。
- 每次登录、注销、Agent 重建递增 generation，拒绝旧 generation 的帧和输入。
- 系统状态存在竞态：后端附加前、Agent 注册时和用户切换事件后都要重新核对身份。
- 断线、Worker 崩溃与切换后端时释放所有修饰键、普通键和鼠标按钮。
- 断线保留 macOS 会话与应用；重新连接必须重新认证和授权。
- 不用杀 WindowServer、PAM session 或仅切换进程 UID 伪造桌面登录。
- 不实现并发独立用户会话；虚拟显示器仍属于实际登录用户的桌面。
- 系统锁屏与物理屏幕遮蔽是不同能力；首版不承诺物理本地屏幕锁住而远端继续工作。

## 7. 开发阶段与验收

### P0：验证协议和当前登录桌面路径

在实现完整管理界面、文件重定向和虚拟显示器之前完成。

**P0-A：协议与认证**

- 搭建最小 Go + FreeRDP Worker，Windows App 显示测试画面并接收键鼠。
- NLA 正确密码通过，错误密码、未知账号、禁用账号失败且不显示桌面。
- 验证机器级凭据存储在没有 GUI 登录的状态下可用。
- Windows App 为主要验收客户端，mstsc 为补充；FreeRDP 客户端互测不能替代二者。

状态：NLA/测试位图/键鼠回显已自动化通过；Windows App 已显示测试画面且输入有回显。
Windows App 的断线重连和第二连接拒绝仍待手工验收；生产账号映射与未登录机器级凭据
不属于当前本机已登录用户原型。

**P0-B：重启登录/锁屏桥接——暂缓（当前范围外）**

不启用系统屏幕共享，不引入 VNC/RFB 依赖，不实现登录窗口、锁屏解锁或登录后端交接。
仅当用户重新提出这类需求时再评估；本阶段不以其可行为前提。

**P0-C：原生桌面 Agent 接入——当前主线**

- 当前已登录用户启动 Agent；验证 ScreenCaptureKit 连续帧及 CGEvent 输入，再接入 FreeRDP Worker。
- 显示真实当前用户桌面，不使用测试图；连接仅在授权目标用户桌面已登录且 Agent 就绪后获准。
- 使用 UID + GeneratedUID/控制台会话信息核对目标身份；其他用户活动时拒绝并清空画面。
- 当前阶段不处理登录窗口或远程解锁；检测到锁屏时按 fail-closed 方式清屏/拒绝/断开。
- 先验证位图链路和坐标映射；VideoToolbox 硬件编码及更高性能优化之后再做。
- LaunchAgent 注册和 TCC 持久性需实测；系统权限只由用户在本机授权，不绕过 TCC。

产物：可复现构建、最小原型、执行命令、测试记录、失败清单和继续/调整结论。

### P1：可用首版

- Go 配置与管理 CLI、账号映射、单连接租约、进程监督、诊断。
- 中文输入、键盘布局、Command/Control 映射、Retina 坐标、文本剪贴板。
- 当前登录用户断线恢复、Agent/Worker 崩溃恢复；远程登录、锁屏解锁仍不在范围内。
- 在用户目标 Mac 和实际 Windows App 上验收，不只运行自动化协议测试。

### P2：体验完善

- H.264、动态分辨率、虚拟显示器、系统音频、文件复制，按顺序加入。
- `CGVirtualDisplay` 作为私有 API 单独隔离、运行时探测；有物理显示器时提供降级。
- 无显示器机器没有物理显示器可降级，必须明确失败状态，不宣称降级保证可用。
- 专门验收代码编辑器彩色小字、快速滚动、窗口切换及视频播放；AVC420 不等同于 AVC444 文字质量。
- 同时复制文件、播放音频、更新画面，检查通道争用和队列延迟。
- 初始体验目标：同内网 1080p 办公场景接近 30 FPS，输入到画面反馈 p95 小于 100 ms；实测后记录目标硬件、网络、CPU 和带宽条件。
- 通过实际 Tailscale 连接验证直连和中继，不能把编码耗时当成端到端延迟。

### P3：部署与稳定性

- Developer ID 稳定签名、公证、安装/卸载、升级回滚和权限持久性。
- 检查新用户首次安装流程；授权需用户完成，root 不等于拥有 TCC 权限。
- 至少 48 小时持续会话、100 次顺序重连、网络中断及睡眠唤醒；确认无持续内存增长、无残留输入。
- 记录 FileVault 与 Tailscale 的恢复矩阵，不在测试中擅自关闭 FileVault 或启用自动登录。

## 8. 新 Session 开工顺序

1. 阅读本文件，检查当前仓库、适用 AGENTS.md 和工具链；保留其他 session 的新增内容。
2. 只读确认目标 Mac 的芯片、macOS 版本、FileVault、登录状态、屏幕共享、Tailscale 安装形式和可用客户端。
3. 可发现的环境信息自己检查；仅在系统设置变更、额外恢复设备、账号体验等实质决策缺失时向维护者澄清。
4. 核对 FreeRDP 当前稳定版、安全更新、构建选项与 NLA API，固定可复现依赖。
5. 完成 P0-A 的 Windows App 手工重连/单连接验收。
6. 按当前范围暂缓 P0-B，直接推进 P0-C 原生当前用户桌面 Agent 接入。
7. P0-C 通过后按 P1 → P2 → P3 推进；若未来恢复登录/解锁需求，再单独重开 P0-B。
8. 测试记录注明版本、硬件、前提、实际结果；明确区分项目方宣称、源码推断和本机实测。

建议后续目录：`cmd/rdpd`、`cmd/rdp-worker`、`cmd/rdpctl`、`internal/auth`、`internal/session`、`internal/ipc`、`native/freerdp`、`native/macos`、`docs/validation`。不要为目录完整而提前生成大量空模块。

## 9. 调研依据

链接对应调研时状态，源码 main/master 可能变化；实施时记录确切版本/commit。

- FreeRDP：https://github.com/FreeRDP/FreeRDP
- 服务端接口：https://github.com/FreeRDP/FreeRDP/blob/master/include/freerdp/peer.h
- 服务端图形路径：https://github.com/FreeRDP/FreeRDP/blob/master/server/shadow/shadow_client.c
- 调研时稳定版：https://github.com/FreeRDP/FreeRDP/releases/tag/3.32.2
- Windows App NLA 回归（已关闭）：https://github.com/FreeRDP/FreeRDP/issues/13549
- GNOME 服务端采用：https://github.com/GNOME/gnome-remote-desktop/blob/master/meson.build
- KDE 服务端采用：https://github.com/KDE/krdp/blob/master/CMakeLists.txt
- macrdp：https://github.com/clintcan/macrdp
- macrdp 认证：https://github.com/clintcan/macrdp/blob/main/src/auth.rs
- macrdp 重启后登录缺口：https://github.com/clintcan/macrdp/issues/237
- macrdp 系统集成经验：https://github.com/clintcan/macrdp/blob/main/docs/macos-gotchas.md
- macrdp 通道争用和客户端差异：https://github.com/clintcan/macrdp/blob/main/docs/known-quirks.md
- ClawTank：https://github.com/HMAKT99/ClawTank
- ClawTank 架构：https://github.com/HMAKT99/ClawTank/blob/main/docs/architecture.md
- ClawTank 架构决策：https://github.com/HMAKT99/ClawTank/blob/main/docs/decisions.md
- ClawTank 测试边界：https://github.com/HMAKT99/ClawTank/blob/main/docs/testing.md
- FreeRDP macOS 集成参考：https://github.com/grio-co/macos-rdp-server
- 该项目关闭 NLA 的配置：https://github.com/grio-co/macos-rdp-server/blob/master/protocol/RDPPeer.c
- 该项目测试记录：https://github.com/grio-co/macos-rdp-server/blob/master/docs/TESTING.md
- Apple 屏幕共享：https://support.apple.com/en-nz/guide/mac-help/mh11848/mac
- Apple Remote Desktop 会话行为：https://support.apple.com/en-om/guide/remote-desktop/apd4f46319e/mac
- Apple FileVault 管理：https://support.apple.com/en-mide/guide/security-pdf/sec8447f5049/1/web/1
- Apple FileVault SSH 手册：https://github.com/apple-oss-distributions/OpenSSH/blob/main/apple_ssh_and_filevault.7
- Tailscale 启动限制相关 Issue：https://github.com/tailscale/tailscale/issues/20361

## 10. 已知陷阱

- 不把 FreeRDP 客户端成熟度直接外推为完整 macOS 服务端成熟度。
- 不把库支持某虚拟通道等同于本项目已经实现完整后端。
- 不把 README 功能列表或未勾选测试项当成本机验证结果。
- 不把系统 LaunchDaemon 能启动当成它可以捕获用户桌面的证据。
- 不认为临时/ad-hoc 签名能跨构建稳定保留权限。
- 不认为端口 3389 是低于 1024 的特权端口；前期资料中的这类表述有误。
- 不把“第三方实现尚未完成”表述为“macOS 绝对不可能实现登录窗口或其他会话形态”。
- 不声称系统屏幕共享桥接已解决登录、解锁和跨后端交接；这些是 P0 的核心验证任务。
