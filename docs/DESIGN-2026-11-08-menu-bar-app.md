# 菜单栏 App 核心设计（RDPServerCore）— 2026-11-08

> **2026-11-09 变更**：手动「释放卡住按键」（SIGUSR1）按钮已从 App 与 Agent 中移除——键盘根因修复后不再需要，
> 断线/接收错误/退出等**自动释放路径保留**。本文中关于该按钮/SIGUSR1 能力探测与发送的描述保留为当时的设计记录，不再代表当前实现。

> 状态：实现完成，本机自动化验证通过（见 §17）；部分 TCC/打包路径为"未验证"，已在 §18 标注。
> 关联：[docs/STATUS-2026-11-08.md](STATUS-2026-11-08.md)（当前状态权威入口）、
> [AGENTS.md](../AGENTS.md)（项目纪律/运维红线）、[PLAN.md](../PLAN.md)（范围）。
> 本文只描述**本次新增的菜单栏 App 核心**，不改动 Worker/Agent 协议与既有部署流程。

产品目标（用户需求）：可拖拽安装的 macOS App，菜单栏图标；点击后的小窗口提供
(1) 服务开关与状态，(2) 当前监听 IP，(3) 权限检查/申请按钮，(4) 可编辑的 RDP 用户名 + 密码。

本次交付的是**可复用核心库** RDPServerCore（Foundation-only，无 SwiftUI/Combine/AppKit 依赖，
可在无 GUI 环境测试）；UI 由 app-ui 在 Sources/RDPServer 中基于本 API 实现，打包由 packaging
负责（dist/RDPServer.app + DMG）。核心不复制 Worker/Agent 逻辑：它管理它们、写它们的私有状态、
解析它们的日志。

---

## 1. 目标与非目标

核心负责：

- 私有数据目录（config.json / SAM / TLS / socket / generation / 日志）的创建、校验、读写；
- Worker（Go + FreeRDP）与桌面 Agent（Swift/ScreenCaptureKit）的进程生命周期：
  启动顺序、就绪判定、崩溃检测、Agent 重启退避、优雅停止、残留 socket 清理；
- RDP 账号密码的校验 + NT 哈希生成（经由 rdpctl 的 stdin 接口）+ SAM 落盘；
- 自签名 TLS 证书生成（含 LAN IP 的 subjectAltName）与按地址变化重建；
- 监听地址模式（仅本机 127.0.0.1 / 私有 LAN auto）与端口配置；
- 权限状态查询/申请（通过 Agent bundle 的 TCC 身份），系统设置深链；
- 线程安全的快照（ServerSnapshot）+ 无头 CLI（--status / --self-test）JSON 契约；
- 自检（SelfTest）：隔离临时目录内的路径/权限/证书/凭据/配置/泄漏检查，可选真实启停。

明确不做（沿用项目边界）：

- 不做远程登录/解锁、不做多用户、不做安装器/公证、不关闭 SIP/不改 TCC 数据库；
- 不读取/复制 旧 .runtime 的凭据（迁移由用户在新 App 里重新设置账号密码）；
- 不修改 launchd（只读检测旧 LaunchAgent plist 并在 UI/文档提示）；
- 不改 Worker/Agent 协议、不改 bin/ 部署产物、不写 .runtime。

---

## 2. 代码结构

    native/macos/Sources/RDPServerCore/
      Version.swift             版本常量（当前 0.2.3）
      SecureFile.swift          0600 原子写 / lstat 校验（tmp+rename，fchmod，fsync）
      ServerPaths.swift         数据目录解析与私有布局校验；socket 路径长度校验
      HelperLocator.swift       helper 解析顺序：env -> bundle Contents/Helpers -> repo/bin -> 可执行文件目录
      Types.swift               ServiceState/AgentState/AddressMode/PrivacyPane/PermissionSnapshot/
                                ServerSnapshot/ServerError/LegacyDeployment
      WorkerConfiguration.swift Worker 配置（与 internal/config/config.go 一一对应）+ 原子读写
      Credentials.swift         账号/密码校验、rdpctl hash-stdin（stdin）、SAM 0600 原子写
      CertificateManager.swift  LibreSSL 证书生成（临时 -config 提供 SAN）、SAN 解析与按需重建
      LANAddress.swift          getifaddrs 私有 IPv4 枚举/默认路由优先（仅用于显示与 SAN）
      ProcessRunner.swift       短生命周期 helper 执行（超时、临时文件捕获输出，避免管道死锁）
      ChildProcess.swift        受管子进程（日志追加、SIGTERM->SIGKILL、reap）
      LogTail.swift             增量日志读取（offset + 半行缓冲）、tail、按大小轮转；AppLog
      PermissionsProbe.swift    Agent 身份权限查询/申请（status / request-permissions 解析）、open URL
      ServerManager.swift       核心状态机：start/stop/restart/refresh/credentials/config/permissions
      StatusReport.swift        --status 的 JSON（snake_case；nil 显式输出 null）
      SelfTest.swift            --self-test 的检查与 JSON（分组命名）
      RDPServerCLI.swift        无头 CLI 入口（--status/--self-test/--data-dir/--version/--help）

    native/macos/Sources/rdp-agent/main.swift
      仅新增一个早期分支：request-permissions（申请缺失权限并打印报告后退出）。

    scripts/test-app-core.py    标准库测试：已知与未知数据目录、--status/--self-test、可选真实启停。

---

## 3. 数据目录与安全模型

解析顺序：显式 URL（UI 的 --data-dir / init 参数） -> 环境变量 RDPSERVER_DATA_DIR ->
~/Library/Application Support/RDPServer。

无头 --status 使用"只解析不创建"路径（--status 不得改磁盘）；其余操作创建布局。

布局（全部在 0700 目录内，文件 0600）：

    <data>/config.json             Worker 配置
    <data>/sam                     RDP 账号 + NT 哈希（MACRDP::<32hex>）
    <data>/key.pem, cert.pem       自签名 TLS 材料
    <data>/certificate-addresses   SAN 记录（0600，元数据，不作为信任来源）
    <data>/agent.sock              Worker<->Agent Unix socket（Worker 创建，0600）
    <data>/worker.lease            App 拉起的 Worker 身份（PID/启动时间/路径，0600）
    <data>/agent-generation        Agent generation 计数（0600）
    <data>/logs/worker.log         Worker stdout+stderr（Go log 与 C event= 行同一文件）
    <data>/logs/agent.log          Agent stdout/stderr
    <data>/logs/app.log            App 生命周期事件（event=... 单行，无凭据/无绝对用户路径）

校验规则（拒绝而不是修复）：

- 数据目录必须是绝对路径、非符号链接、由当前 UID 拥有、权限 0700；
- 日志目录同样 0700；
- Agent socket 绝对路径 UTF-8 字节数 +1 < 104（AF_UNIX sun_path 限制），父目录即数据目录；
- SAM/证书/key/config 必须是 0600 普通文件（Worker 的 config.PrivateFile 要求同样条件）。

写文件统一 temp file + rename（同目录），fchmod 到目标权限后 fsync，避免崩溃留下半个配置。

---

## 4. 生命周期状态机

    disabled --start--> starting --(worker 就绪 + agent 启动)--> running
                            |                                        |
                            | worker 失败/超时                        | worker 意外退出
                            v                                        v
                          error <------------------------------------+
    running/error --stop--> stopping --> disabled
    running --stop(agent 先,worker 后)--> stopping --> disabled

- ServiceState: disabled / starting / running / stopping / error。
- AgentState: waiting（已启动但未观测到帧）/ capturing（近 5s 内收到帧）/ failed（多次崩溃或启动失败）。
- 无凭据时 start() 不进入 error 而是维持 disabled 并返回 ServerError.notConfigured
  （UI 以 configured 字段渲染"首次设置"）。
- 快照字段 needsRestart：运行中改了 config.json（地址/端口/账号）时为 true，
  UI 显示断线警告并调用 restart()。

---

## 5. 启动序列（关键实现细节）

1. 清理上一轮崩溃/SIGKILL 遗留的 Worker：读取 `<data>/worker.lease` 并按
   PID + 启动时间 + 可执行路径校验身份，SIGTERM 后最多等 10s 再 SIGKILL；
   lease 缺失/不可用时用 `/bin/ps` 扫描同一 `-config <abs>/config.json` 的
   `rdp-worker` 回退。仍有进程存活时拒绝启动（不再 spawn 一个会撞端口的 Worker）；
2. 重新从磁盘读取 config.json（external edit 生效），要求 SAM 里有合法账号；
3. 校验配置（address/port/account/绝对路径，规则与 Go 侧一致）；
4. 确保证书：按当前地址集（127.0.0.1 + LAN 模式下的私有 IPv4）检查 SAN，不匹配则重建；
5. 若 config 与磁盘不一致（例如首次保存账号）则写回；
6. 轮转超过 32 MiB 的 worker.log / agent.log 到 .1（只在写者停止时做，避免丢日志）；
7. **先 unlink 旧 agent.sock**（见下方陷阱）；
8. spawn Worker：rdp-worker -config <abs> -agent-socket <abs>，stdout/stderr 追加到 logs/worker.log；
9. 写入 `<data>/worker.lease`（0600；PID + 启动时间 + 实际可执行路径；写失败只记日志，
   下次启动仍有 `/bin/ps` 回退）；
10. 就绪判定（最多 10s，见 §5.1）；成功后记录监听地址；
11. spawn Agent：RDPAgent.app/Contents/MacOS/rdp-agent stream-snapshot <socket> 0 0 <generation>，
   环境 RDP_AGENT_NO_PERMISSION_REQUEST=1 RDP_AGENT_DELTA_FRAMES=1 RDP_AGENT_CAPTURE_STREAM=1
   RDP_AGENT_TARGET_FPS=60 RDP_AGENT_VIRTUAL_DISPLAY=1（与 scripts/run-agent-stream.sh 一致）；
12. 写入 agent-generation（0600），状态置 running，启动 1s 监控定时器。

### 5.1 就绪判定

"TCP connect 127.0.0.1/LAN:port 成功" 为最终判据；同时解析日志中的
event=listening、event=lan_address_selected/event=lan_worker_started address=...
（LAN 模式下 Worker 自己选地址并打印，App 只读回该地址用于显示）。
超时或进程提前退出时，错误信息带最后 4~5 行 event= 日志，UI 直接展示，便于排查。

### 5.2 Socket 陷阱（必须遵守）

若 Worker 启动时 agent.sock 已存在，C 侧 listener 会**静默放弃**（之后会话被拒
reason=no_frame）。因此：每次启动前 unlink、每次停止后 unlink；停止顺序为
Agent -> Worker -> unlink，Worker 被 SIGKILL 也仍会 unlink。

---

## 6. 停止、崩溃与重启策略

- 停止：先 SIGTERM Agent（最多等 5s，再 SIGKILL）——它需要恢复显示排列；
  再 SIGTERM Worker（最多等 10s，再 SIGKILL）；最后 unlink socket、清理状态。
  Worker 的 `address:auto` 监督进程还需最多 5s 停止其 FreeRDP 子进程，Worker
  宽限期必须大于该窗口，避免 App 提前 SIGKILL Worker 而遗留监听进程。
  所有 Worker 终止路径（正常停止、启动就绪失败、deinit 兜底）都必须使用
  `workerStopGrace`，不能再用 1~2s 的短宽限，否则同样会留下孤儿监听进程。
- 启动：先读取 `<data>/worker.lease`（0600，PID + 进程启动时间 + 可执行路径），
  校验身份后 SIGTERM，超过 `workerStopGrace` 再 SIGKILL；lease 缺失/不可用时用
  `/bin/ps` 扫描命令行为同一 `-config <data>/config.json` 的 `rdp-worker` 作为
  旧版本回退。清理失败（仍有进程存活）时拒绝启动并在 UI 显示 Worker 启动失败，
  不再盲目 spawn 一个会撞端口的 Worker。
- App 被 `SIGKILL` 或崩溃：App 拉起的 Worker 环境中有
  `RDP_WORKER_MANAGED_BY_APP=1`，Worker 每 500ms 检查父进程；被 launchd
  reparent（`getppid()==1`）后记录 `event=worker_parent_exited`，`address:auto`
  监督进程先停止 FreeRDP 子进程再退出，普通 Worker 直接退出。手工/launchd
  形态不带该变量，生命周期不变。
- `address:auto` 监督进程在每次启动子进程前 unlink 旧 socket：子进程崩溃或
  被 SIGTERM 后不会自己清理 socket，不 unlink 会让下一次 C listener 静默
  拒绝监听（`reason=no_frame`）。
- Worker 意外退出：状态置 error，lastError 含退出码与日志尾部，终止 Agent、unlink socket。
  （不自动重启 Worker：每次重启都可能断开会话，交由用户点开关。）
- Agent 意外退出：30s 窗口内最多重启 3 次（间隔 300ms），超过则 AgentState=failed 并记录原因；
  generation 每次 +1（取 generation 文件、内存观测值、Worker 日志尾部 generation= 的最大值 +1，
  防止 generation 回退被 Worker 判 stale）。
- 权限申请成功后，若 Agent 因缺少权限而 failed，自动重新拉起 Agent。
- App 退出路径：shutdown() 幂等；deinit 兜底终止子进程并 unlink socket，避免孤儿进程。

---

## 7. 配置模型（config.json）

与 internal/config/config.go 完全一致（未知字段会被 Go 拒绝，因此只写这些键）：

    {
      "address": "127.0.0.1" | "auto" | "<显式私有 IPv4>",
      "allow_lan": false | true,
      "port": 3389,                       // 1024..65535
      "account": "<user>",                // 小写 [a-z0-9_.-]{1,64}；首次运行可为空
      "enabled": true,
      "test_pattern": false,              // 产品默认 false（真实桌面）
      "clipboard": true,                  // 产品默认 true
      "certificate": "<abs>/cert.pem",
      "key": "<abs>/key.pem",
      "sam": "<abs>/sam"
    }

地址模式：

- loopback：address="127.0.0.1", allow_lan=false（默认）；
- lan：address="auto", allow_lan=true —— Worker 自己挑唯一的私有 IPv4 并跟随变化
  （supervisor 子进程；日志 event=lan_address_selected / event=lan_worker_started /
  event=lan_address_changed）。App 不硬编码 LAN IP，只从日志读回用于展示。

注意：Windows 客户端需要证书 SAN 含其连接使用的 IP。LAN 模式下 App 在**启动时**把当前
私有 IPv4 写入证书 SAN；运行中 LAN 地址变化时 Worker 会跟随，但证书不会热更新
（见 §18 未验证/TODO）。

---

## 8. 凭据

- 校验：账号 [a-z0-9_.-]{1,64}；密码非空、≤4095 UTF-8 字节、不含换行/NUL。
- 哈希：spawn rdpctl hash-stdin，密码只经 stdin 传入（绝不进 argv/环境/日志/文件）；
  输出必须是 32 位小写十六进制，否则报错。
- 落盘：sam 内容为 "account:MACRDP::<hash>:\n"（末尾换行），0600 原子写。
- 密码明文不落盘；SelfTest 会扫描整个数据目录（含日志）确认没有明文密码，
  且 NT 哈希只出现在 sam（不出现在 config/logs）。
- 运行中保存凭据只写文件并置 needsRestart（Worker 在启动时读取配置/证书），
  由 UI 提示断线后 restart()。

---

## 9. 证书

- 使用系统 /usr/bin/openssl（LibreSSL）。LibreSSL 的 x509 子命令不支持 -addext/-ext，
  因此 SAN 通过临时 openssl 配置文件提供（[req] x509_extensions=v3_req；
  [v3_req] subjectAltName=IP:127.0.0.1,IP:<lan>），命令：
      openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365
        -keyout <tmp key> -out <tmp cert> -subj /CN=localhost
        -config <tmp cnf>
  生成后 chmod 0600、rename 到 key.pem/cert.pem，删除临时文件；
- SAN 校验用 openssl x509 -noout -text 解析 "IP Address:"，与期望地址集比较，
  不一致（例如 LAN IP 变化）则在下次启动时重建；
- 证书为开发用自签，客户端会提示不受信任；不做 Developer ID/公证（项目边界）。

---

## 10. 权限与 TCC 身份（重点）

TCC（屏幕录制、辅助功能、完全磁盘访问）授予的是 **Agent 的 bundle 身份**：
com.rdp-server.agent（app bundle 内的可执行文件），**不是**菜单栏 App 本身。
因此权限查询/申请都由 App spawn 嵌套 Agent 二进制完成：

- 查询（无弹窗）：RDP_AGENT_NO_PERMISSION_REQUEST=1 rdp-agent status
  -> 解析 "screen_recording=granted|missing accessibility=granted|missing"；
- 申请：rdp-agent request-permissions（本次在 main.swift 新增的分支：调用
  CGRequestScreenCaptureAccess / AXIsProcessTrustedWithOptions 后打印报告即退出）；
  旧版 Agent 没有该命令时回退为不带 NO_PERMISSION_REQUEST 环境运行 status（main() 会先申请）。
- 系统设置深链（App 只打开，不授权）：
      x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
      x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
      x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
- 文件剪贴板从受保护目录读取还需要给 RDPAgent.app 完全磁盘访问（既有项目限制）。
- 授权后通常需要重启 Agent 进程才能生效；如果 Agent 因缺权限 failed，App 会在
  requestPermissions 成功后自动重拉 Agent。

app-ui 的 UI 建议：权限行显示 screen recording / accessibility 两项 + "检查权限"
"打开系统设置" 按钮；桌面未就绪时在服务状态里提示"远程连接会被拒绝（无 Agent 帧）"。

---

## 11. 公共 API（RDPServerCore，供 Sources/RDPServer 使用）

核心不依赖 SwiftUI；UI 用一个 @MainActor ObservableObject 包装 ServerManager 并轮询
refresh()。所有 async 方法内部切到后台队列，不会阻塞主线程；snapshot() 是加锁读，永远可调用。

    public enum ServiceState { disabled, starting, running, stopping, error }        // String rawValue
    public enum AgentState { waiting, capturing, failed }
    public enum AddressMode { loopback, lan }
    public enum PrivacyPane { screenRecording, accessibility, fullDiskAccess }
    public enum ReleaseStuckKeysResult { released, agentNotRunning, notSupported(String), failed(String) }
    public enum CredentialValidationError { usernameInvalid, passwordInvalid, passwordTooLong, writeFailed(String) }

    public struct PermissionSnapshot {
        screenRecording, accessibility: Bool
        isAvailable: Bool; lastError: String?; checkedAt: Date?
        desktopReady: Bool; summary: String
    }

    public struct ServerSnapshot {
        state: ServiceState; configured: Bool
        address: String?          // "host:port"（仅在监听时）
        listenHost: String; port: Int; allowLAN: Bool
        account: String?; principal: String?    // MACRDP\user
        permissions: PermissionSnapshot
        agentState: AgentState; agentDetail: String?
        workerRunning: Bool; workerPID/agentPID: Int32?
        generation: UInt64?; needsRestart: Bool; lastError: String?
        legacyLaunchAgentInstalled: Bool
        logsDirectory, dataDirectory: URL
    }

    public final class ServerManager {
        init(dataDirectory: URL? = nil, helpersDirectory: URL? = nil) throws
        paths: ServerPaths; helpers: HelperLocator
        snapshot() -> ServerSnapshot
        refresh() async -> ServerSnapshot
        start()/stop()/restart()/setEnabled(Bool) async -> ServerSnapshot
        saveCredentials(account:password:) async throws -> ServerSnapshot
        setAddressMode(AddressMode) / setPort(Int) async throws -> ServerSnapshot
        requestPermissions() async -> PermissionSnapshot
        releaseStuckKeys() async -> ReleaseStuckKeysResult
        openLogsDirectory() / openDataDirectory() / openSystemSettings(PrivacyPane) -> Bool
        recentLogLines(limit:) / recentAgentLogLines(limit:) -> [String]
        shutdown() async
        // CLI/自检用同步变体：startNow(timeout:)、stopNow()、refreshNow()、
        // saveCredentialsNow(...)、setAddressModeNow(...)、setPortNow(...)、
        // requestPermissionsNow()、releaseStuckKeysNow()、shutdownNow()
        static validateUsername(String) / validatePassword(String) -> CredentialValidationError?
        static principal(for: String) -> String
    }

    // 无头（不启动服务、不创建数据目录）
    public struct StatusReport: Codable  { ok, app_version, data_directory, state, configured, enabled,
        address, listen_host, port, allow_lan, account, principal,
        permissions{screen_recording,accessibility}, agent{state,detail},
        worker{running,pid}, last_error, logs_directory, error }
    public struct SelfTestReport: Codable { ok, checks[{name,ok,detail}], data_directory, started_service, error }
    public enum RDPServerCLI {
        static run(arguments:environment:) -> Int32?     // 返回 nil = 不是核心 CLI 调用（UI 启动）
    }

releaseStuckKeys()：向本 App 自己拉起的 Agent 子进程发 SIGUSR1（语义由 input-diag 在 Agent
侧实现：post 所有修饰键 keyup、不打断采集）。若 Agent 不是本 App 的子进程（例如旧 launchd
部署）返回 notSupported/agentNotRunning，不做任何猜测性操作。App 记录
event=release_stuck_keys result=... 到 logs/app.log。

**Agent 侧两条安全约束（input-diag 契约，DIAGNOSIS-2026-11-08-keyboard-swallowed-input §8）**：

1. SIGUSR1 只在 stream-snapshot 命令里注册 handler。App 只对**自己 spawn 的采集子进程**
   （stream-snapshot，PID 由 ChildProcess 保存）发信号；virtual-display 子进程是 Agent 自己
   的子进程、同一个二进制的另一个子命令、**没有** handler，绝不能对它发信号（核心从不持有/
   猜测它的 PID）。
2. 从进程启动到 handler 注册之间有一个很小的窗口。因此 releaseStuckKeys() 会先等待
   Agent 真正开始出帧（最近 5s 内收到帧，最多等 2.5s）才发信号；等不到则返回
   .failed("not capturing yet") 并记 event=release_stuck_keys result=agent_not_ready，
   绝不赌启动窗口。旧 Agent（无 handler）由能力门禁在发信号之前拦下。

信号语义与验证证据（与 input-diag 对齐）：核心以 `kill(pid, SIGUSR1)` 成功作为
"已投递"（不解析日志、不做二次确认；按钮可重复点击，sweep 幂等）。排查"是否真的处理了"时看
Agent 日志的完整行 `event=input_release_all reason=signal pressed_keys=N pressed_unicode=N swept=9`
——注意该 event 也被其它释放路径（peer_release_all / socket_closed / input_receiver_error /
termination）使用，**不能**把裸标记 `input_release_all` 的出现当作"信号已被处理"的证据；
能力检测使用裸标记只是判断构建是否包含 handler，语义不同。

**能力门禁（重要）**：SIGUSR1 的默认动作会**终止**进程，因此绝不能对没有实现该 handler 的
旧 Agent 发送。核心提供 supportsReleaseStuckKeys() -> Bool：对 Agent 可执行文件做保守的
字节标记扫描（新 handler 会写日志 event=input_release_all reason=signal，扫描标记
"input_release_all"；按路径+大小+mtime 缓存，重新部署后自动失效）；未通过时不发信号，
releaseStuckKeys() 返回 notSupported 并记录 result=not_supported。UI 必须用该 API
禁用/隐藏"释放卡住按键"按钮。部署顺序：先更新 Agent（随后更新 App），再启用该按钮；
--self-test 的 agent.release_stuck_keys 检查会给出 supported/unsupported 供打包断言。

---

## 12. 无头 CLI 契约（--status / --self-test）

用法：

    RDPServer --status [--data-dir PATH] [--data-dir=PATH]
    RDPServer --self-test [--data-dir PATH] [--data-dir=PATH]
    RDPServer --version | --help

环境变量：

    RDPSERVER_DATA_DIR       数据目录默认值（--data-dir 优先）
    RDPSERVER_HELPERS_DIR    helper 目录覆盖（测试/打包验证用）
    RDPSERVER_SELFTEST_START 设为 1 时 --self-test 额外真实启停 Worker+Agent（默认不启动）

约定：

- --status：stdout 恰好一个 JSON 对象（snake_case，nil 显式输出 null），exit 0；
  不创建数据目录、不启动 Worker；权限字段通过嵌套 Agent 的 status 查询获得（不弹窗）；
  不输出任何凭据（只有裸账号名）。
- --self-test：stdout 恰好一个 JSON 对象；exit 0 当且仅当全部检查通过；
  人类可读的每项检查写到 stderr。传入 --data-dir 时结果留在该目录（调用方清理）；
  不传时使用 /tmp 下 8 位随机私有目录并在结束时删除（选 /tmp 是为了让 socket 路径远低于 104B）。
- 退出码：0 成功/通过；1 未通过；2 参数错误。
- 两者都不读 .runtime、不写 bin/、不改 launchd。

--status 示例（首次运行、未配置）：

    {
      "account": null, "address": "127.0.0.1:3389", "agent": {"detail": null, "state": "waiting"},
      "allow_lan": false, "app_version": "0.2.3", "configured": false,
      "data_directory": "/tmp/x/data", "enabled": false, "error": null, "last_error": null,
      "listen_host": "127.0.0.1", "logs_directory": "/tmp/x/data/logs", "ok": true,
      "permissions": {"accessibility": true, "screen_recording": true},
      "port": 3389, "principal": null, "state": "disabled", "worker": {"pid": null, "running": false}
    }

---

## 13. 自检内容（--self-test）

检查按前缀分组，便于 packaging 在不同机器上断言不同子集：

- helpers.*：helper 目录存在；rdp-worker/rdpctl/RDPAgent.app/openssl 可执行。
- paths.*：数据目录 0700 且属主是当前用户；logs 0700；socket 路径 <104B；目录内文件均 0600。
- certificate.*：生成成功、key/cert 0600、SAN 含 127.0.0.1。
- credentials.*：通过 rdpctl stdin 写入随机账号密码；sam 0600；哈希 32 hex；账号回读一致。
- config.*：写入随机空闲 loopback 端口；0600；JSON 可回读且等值；address=127.0.0.1/
  allow_lan=false；路径绝对；config 内无明文密码。
- agent.permission_query：以嵌套 Agent 身份查询权限（不弹窗）；解析成功即 ok
  （granted/missing 只作为 detail，不算失败）。
- agent.release_stuck_keys：信息性检查（ok 恒为 true）；detail 为 supported 或
  "unsupported (old Agent build; ...)"。打包校验应断言 bundled Agent 为 supported。
- secrets.*：数据目录（含日志）无明文密码；NT 哈希只出现在 sam。
- worker.*（可选，RDPSERVER_SELFTEST_START=1）：worker.started / worker.listening /
  worker.tcp_connect。
- agent.frames（可选）：Agent 帧流；若权限未授予则 ok=true 且 detail 写
  "skipped: ..."（跨机器不硬失败），权限已授予时必须观测到 capturing 帧。
- cleanup.*：宽限不变量；`--with-service` 时 seed 一个 stale Worker 并断言
  `stale_worker_lease`/`stale_worker_scan`/`stale_worker_removed`/`stale_worker_lease_source`
  均通过；停止后状态 disabled、无残留 PID、socket 与 worker.lease 已删除。

安全约束：自检只使用临时数据目录、随机 loopback 端口、随机账号密码；不连接任何 RDP 客户端
（不会触发 Agent 的虚拟显示器）；结束时停止所有子进程。

---

## 14. 日志与隐私

- worker.log / agent.log 是子进程 stdout/stderr 原样追加（event= 行保持既有词表，
  Python 测试依赖这些子串，不重命名）。
- app.log 只记 App 决策：service_starting/service_started/service_start_failed/
  service_stopped/worker_exited_unexpectedly/agent_started/agent_restarted/
  agent_restart_exhausted/credentials_saved/permissions_requested/release_stuck_keys 等，
  不含凭据、剪贴板内容、按键文本、绝对用户文件路径。
- 轮转：启动前 >32MiB 的 worker.log/agent.log 移到 .1；app.log 超过 4MiB 也轮转。
  注意：Worker 每帧都会写 event=agent_frame_received，长时间运行日志会持续增长；
  运行中不做热轮转（见 §18）。

---

## 15. 失败模式与排查

    Worker 启动即退出         lastError 带退出码+日志尾部；常见：config 权限/路径不合法、
                              端口被占、address auto 无合格接口。start() 返回 state=error。
    Worker 起来了但会话被拒    socket 残留（reason=no_frame）。App 已保证启动前/停止后 unlink；
                              若是外部进程残留，stop/start 一次即可。
    Agent 反复崩溃            AgentState=failed + agentDetail（日志尾部）；常见：屏幕录制权限缺失、
                              显示器不可用。授权后点"申请权限"会自动重拉。
    证书 SAN 不含客户端 IP     LAN 模式下把 App 停掉再启动（启动时按当前私有 IPv4 重建证书）；
                              运行中 LAN IP 变化需重启服务。
    端口/地址改了但没生效      snapshot.needsRestart=true：调用 restart()。
    权限始终 missing          确认是用 RDPAgent.app（bundle id com.rdp-server.agent）身份；
                              ad-hoc 重打包后 cdhash 变化可能重新弹窗，需重新授权。
    legacy LaunchAgent 存在    snapshot.legacyLaunchAgentInstalled=true：建议先
                              python3 scripts/agent-launchd.py uninstall，否则旧 Agent 会继续
                              连 .runtime/agent-compat.sock 崩溃重试。App 不会自动改 launchd。
    释放卡住按键按钮置灰     supportsReleaseStuckKeys()=false：当前 Agent 是旧版本（无 SIGUSR1
                              handler）。先成对部署新 Agent/App；对旧 Agent 发 SIGUSR1 会杀掉它。

---

## 16. 从旧部署迁移（用户可见说明）

- 旧 .runtime 不要动（账号/证书不自动迁移、不读取）；
- 使用新 App 前建议卸载旧 LaunchAgent：python3 scripts/agent-launchd.py uninstall（会停止旧 Agent）；
- 在新 App 里重新设置 RDP 用户名 + 密码（App 生成独立的 SAM/证书，存在
  ~/Library/Application Support/RDPServer）；
- 权限（屏幕录制/辅助功能）若按 bundle id/ad-hoc 签名复用，可能无需重新授权；
  若系统重新弹窗，按 App 内按钮引导授权。

---

## 17. 开发与测试

    # 核心库编译
    swift build -c release --package-path native/macos --target RDPServerCore
    # 全包（含 UI/Agent）
    swift build -c release --package-path native/macos

    # 核心无头测试（不启动服务）
    python3 scripts/test-app-core.py
    # 追加隔离的真实 Worker+Agent 启停（随机端口/临时目录；需要 TCC 已授权）
    python3 scripts/test-app-core.py --with-service

    # 手动检查
    ./native/macos/.build/release/RDPServer --status --data-dir /tmp/x/data
    RDPSERVER_SELFTEST_START=1 ./native/macos/.build/release/RDPServer --self-test --data-dir /tmp/x/data

本机实测（2026-11-08，开发机）：

- swift build release（全包）通过；
- python3 scripts/test-app-core.py → ALL TESTS PASSED；
- python3 scripts/test-app-core.py --with-service → ALL TESTS PASSED（worker 监听随机 loopback
  端口、Agent 帧流 captured、停止后无残留 PID/socket）。

测试脚本不依赖 .runtime，HELPER 目录用符号链接指向 bin/（只读），HOME 重定向到临时目录。

---

## 18. 未实现 / 未验证 / TODO

未验证（不要当作已完成）：

- DMG 安装后（dist/RDPServer.app）在**另一台** Mac / 干净 TCC 状态下的首次授权流程；
  本机验证的是已授权 bundle id 的复用。
- Windows 客户端经 LAN 模式连接新 App 证书（SAN 含 LAN IP）的证书提示行为。
- releaseStuckKeys()：SIGUSR1 语义由 input-diag 在 Agent 侧实现（已合入源码，属日志/API 契约名
  event=input_release_all，按 AGENTS §7.3 不会重命名），核心负责发信号 + 能力门禁 + 出帧后
  才发的时序保护。已在隔离环境用新 Agent 二进制验证（PID 不变、仍 capturing、Agent 日志出现
  input_release_all）；真机/正式部署后的配对验证仍待做。更干净的长期方案是给 Agent 增加显式
  capabilities 命令（记录为后续 follow-up；维护者若排期再切换消费方，见 §10）。
- 运行中 LAN 地址变化后的证书热更新（当前仅启动时按地址重建）。
- 长时间运行日志增长（Worker 每帧 event=agent_frame_received）没有运行中热轮转。

已知 TODO / 后续可做：

- 运行中日志轮转（需要与 Worker 协作文档/PIPE 方案，或给 Worker 增加日志级别/采样参数）；
- 证书 SAN 在 LAN 地址变化时自动重建 + 按需重启（需维护者确认断线）；
- 把旧 LaunchAgent 卸载做成 App 内的显式操作按钮（当前只提示，不自动执行）；
- 本核心没有单元测试 target（Package.swift 无 testTarget，维护者拥有 Package.swift）；
  当前靠 scripts/test-app-core.py 与 --self-test 覆盖；如需可加 plain precondition 测试可执行。

---

## 19. 模块分工

- UI 模块（Sources/RDPServer）：SwiftUI 菜单栏 UI，包装 ServerManager；CLI 入口调用
  RDPServerCLI.run(arguments:)，返回 nil 时启动 GUI。
- 打包模块：组装 dist/RDPServer.app（Contents/Helpers/{rdp-worker,rdpctl,RDPAgent.app}、
  Contents/Frameworks dylib 重定位）、ad-hoc 签名、DMG；用 --status/--self-test 做 bundle 校验。
- 维护者：Package.swift、Makefile（app-build/app-dmg/test-app/test-app-bundle 目标）、提交。
