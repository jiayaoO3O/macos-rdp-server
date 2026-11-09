# P0-C：原生桌面 Agent 探针（首个可构建原型）

日期：2026-11-01。已完成独立命令行探针、权限状态查询、单帧采集和连续帧计数验证；
尚未完成 LaunchAgent 注册、用户身份核验、RDP 接入或真实桌面输入验收。

## 本机前提与只读检查

- Apple Silicon、macOS 27.x，当前控制台用户已登录。
- 内建 Liquid Retina 显示器在线，系统报告分辨率 2560×1664。
- `CGPreflightScreenCaptureAccess()` 返回 false；`AXIsProcessTrusted()` 返回 false。
- 探针输出：

  ```text
  screen_recording=missing accessibility=missing desktop_ready=false
  ```

前一轮只读检查没有调用授权提示 API，也没有请求屏幕内容、移动鼠标或更改系统
隐私权限。本轮在系统提示后授权；屏幕录制与辅助功能最终均由预检查确认
granted。
`desktop_ready=false` 是刻意的：仅有系统权限不等同于 Agent 注册、会话身份核验、
采集首帧和输入通道均就绪。

## 命令与权限申请行为

```sh
make agent-check
make agent-build
bin/rdp-agent status
bin/rdp-agent displays
bin/rdp-agent capture 0 /path/to/capture.png
bin/rdp-agent capture-stream 0 3
bin/rdp-agent move 100 100
```

- 每次启动先检查权限；缺失时调用 `CGRequestScreenCaptureAccess()` 和
  `AXIsProcessTrustedWithOptions(...kAXTrustedCheckOptionPrompt...)`，再执行子命令。
  不带参数默认为 `status`，因此现在直接运行 `bin/rdp-agent` 也会申请缺失权限。
  对 `capture` / `move`，申请流程后仍会核查权限；未授权时返回明确错误。
- 即使调用申请 API，系统是否、何时展示提示由 macOS TCC 管理。开发期 CLI 的
  TCC 身份和授权持久性尚未实测；授权后可先退出并重新运行 `bin/rdp-agent status`。
- `displays` 和 `capture` 使用 ScreenCaptureKit；`capture` 只写一张 PNG，不传输原始
  帧或连接 RDP Worker。
- `capture-stream` 使用 `SCStream` 连续接收屏幕帧，只计数并记录最后一帧尺寸；不保存、
  展示或发送帧，也不连接 RDP Worker。持续性和实际尺寸对应关系仍需进一步测量。
- `move` 仅在 Accessibility 已授权时发送显式鼠标移动事件；不点击、不按键。本轮
  未执行该命令。
- 捕获和输入权限目前应由用户在 System Settings > Privacy & Security 中授权给
  实际运行的签名应用。开发期 SwiftPM 命令行程序的 TCC 身份/权限持久性尚未验证；
  不要据此假定未来 LaunchAgent 已获得权限。
- 该探针最低部署版本暂定 macOS 14，因为采用 `SCScreenshotManager` 单帧采集 API；
  若目标系统更旧，需要另行评估 `SCStream` 路径。

## 已执行验证

- 先添加 `PermissionSnapshot` 行为断言，再运行 `swiftc`；首次按预期因类型尚不存在
  而失败（RED）。实现模型后，`make agent-check` 通过（GREEN）。
- `CaptureProgress` 测试先按预期因类型不存在而失败（RED），实现后 `make agent-check`
  通过（GREEN），覆盖无效尺寸拒绝、帧计数、最新尺寸和目标帧数判断。
- 新增 Go/Swift 共用的 `RDPA` IPC v1 消息封装，带长度前缀、版本和类型校验，单条
  payload 上限 64 KiB；Go 测试先按预期因协议类型不存在而失败，随后通过分片写入、
  无效头、未知类型/版本、截断消息和超限 payload 测试。帧像素分多条有界 chunk 消息
  传输，不使用 JSON/base64。
- `swift build --package-path native/macos` 通过，生成 `rdp-agent`。Command Line
  Tools 的 SwiftPM 构建打印两个缺失 Developer/Frameworks 搜索路径的 linker 警告；
  不影响本机 arm64 构建。
- 旧版 `bin/rdp-agent status` 输出两项权限缺失；新版启动会主动申请缺失权限。
- 授权后，`bin/rdp-agent status` 输出
  `screen_recording=granted accessibility=granted desktop_ready=false`。
- `bin/rdp-agent displays` 成功列出 `index=0 id=1 width=1470 height=956`。
- 授权后执行一次 `capture 0`，ScreenCaptureKit 成功捕获 1470×956 PNG。截图
  仅临时写入批准的临时目录，验证后立即删除；没有读取/展示截图，也没有加入仓库。
- `make agent-build` 通过。执行 `bin/rdp-agent capture-stream 0 3` 得到
  `frames=65 display=1 width=1470 height=956`；帧只在进程内读取后丢弃，没有存盘。
- 查询 `CGDisplayMode.pixelWidth/Height` 后发现活动显示模式约为 2.9K（NSScreen points
  1470×956）。`SCScreenshotManager` 成功捕获约 2.9K；SCStream 在该尺寸下未输出帧，
  因此新增高分辨率 `stream-snapshot` 路径。通过临时本机 Unix socket 只校验协议和尺寸，
  收到 7 帧 2940×1912（每帧约 22.5 MB），未保存或查看像素。
- 再次验证高分辨率路径：Worker 原生侧收到 101 帧约 2.9K（每帧 22,485,120 字节）；
  `rdp-live.rdp` 请求 2560×1664。RDP 会话中的视觉清晰度及端到端帧率仍待真机验收。
- Worker C 原生侧现可创建 mode 0600 的 Unix socket，使用 `getpeereid()` 拒绝不同 UID，
  解析 RDPA v1 的帧元数据/顺序分块，在原生内存中只保留最新一帧（上限 64 MiB）。
  RDP 输出按客户端请求尺寸缩放并用 FreeRDP Planar 编码；若无 Agent 帧，
  默认拒绝 RDP 会话；四色测试图只在显式 `test_pattern=true` 时开启。Agent socket 路径
  须位于当前用户拥有且权限 0700 的目录。
- 使用真实 `rdp-agent stream` 将 26 帧（每帧 5,621,280 字节）送到 Worker；日志确认
  `agent_frame_received`，另一次 FreeRDP 客户端连接期间确认 `desktop_frame_sent`。探针
  收到 32 bpp 压缩 bitmap update，但因其只识别四色测试图，退出码 11；这不证明
  Microsoft Windows App 的真实桌面图像已正确显示。
- 测试画面现必须通过配置显式设置 `test_pattern=true`；缺省 false 时，RDP `Activate`
  前没有 Agent 帧会被拒绝，禁止静默回退为四色图。自动化协议测试明确启用测试模式。
- 新增 live-mode 尺寸集成回归：通过 Unix socket 送入 1470×956 帧，FreeRDP 探针以
  1470×956 建立图形面并收到单个 bitmap update batch（含整屏 tile）；Worker 从首帧设置
  RDP 会话尺寸。此前每块单独发包可能造成 Windows App 逐块呈现/撕裂，现合并为单帧批量
  更新。根目录 `rdp-live.rdp` 对应该本机采集尺寸。后续显示器变化暂不动态调整现有会话。
- 新 worker 以 live mode 启动时，无 Agent 帧的 RDP 探针连接被拒绝且未收到任何位图更新。
  另一轮真实采集连接期间 C Worker 记录 `desktop_frame_sent generation=1 frame_id=26`；
  这是服务端发送证据，不等价于 Windows App 已正确呈现真实桌面。
- 最新 live-mode 手工采集窗口运行 30 秒，Agent 发送 152 帧（1470×956），C Worker 日志
  逐帧确认完整接收（generation 2）。
- 此前用 Windows App 确认看到了当前终端应用的真实帧，但当时 Worker 会话仍为
  800×600，显示面积/清晰度不足。随后增加 1470×956 live profile 与客户端尺寸协商；
  反馈该分辨率版本窗口大小正确、画质更清晰，但当时仍有撕裂。
- 输入实现已接入：Worker 将 RDP scancode/Unicode 和鼠标坐标归一化后经 Unix socket 发给
  Agent；Agent 使用 CGEvent 注入键盘、鼠标移动/按钮/滚轮，并在断线时释放已按下的键和
  鼠标按钮。MacKeyMap 有基础美式键位映射测试；实际 Windows App 输入注入尚未人工验收。
- FreeRDP/WinPR 已重新构建为 `WITH_CHANNELS=ON`（关闭不需要的 USB/URBDRC）；Live Worker
  可选建立 CLIPRDR server context。Agent 轮询 macOS 文本剪贴板并通过 IPC 同步，RDP 客户端
  CF_UNICODETEXT 请求/响应已接线；`clipboard` 配置默认 false，以免影响初始连接稳定性。
  需先通过 live Windows App 验收，再显式开启该选项测试文本剪贴板。文件列表/内容
  (`CF_HDROP`、FileGroupDescriptor/FileContents) 尚未实现。
- 客户端分辨率现以 RDP 客户端 core data 请求尺寸为准；新集成回归使用源帧 1470×956、
  客户端请求 1024×768，确认服务端 RDP Surface/GDI 均采用请求尺寸。会话中途动态改尺寸
  尚未支持；剪贴板文本/文件通道亦未接入。
- 批量整帧更新版本的 30 秒复测中，Worker 日志记录 Windows App 完成认证，并持续发送
  多个 live `desktop_frame_sent` 帧；真机确认撕裂消失、清晰度更好、窗口尺寸合适。
- 当前 `make check`、`make test-protocol`（11/11）、`make agent-check` 和
  `make agent-build` 均通过。SwiftPM 仍有 Command Line Tools 搜索路径警告，不影响构建。
- 2026-11-02 晚间复测时 `bin/rdp-agent displays` 返回空列表；只读检查显示内建显示器
  `Online: Yes` 但 `Display Asleep: Yes`。因此该次 `stream-snapshot` 报 display index 不可用，
  Worker 没有新帧，会按 fail-closed 策略拒绝/断开 RDP。未尝试远程唤醒或修改电源设置；
  后续验证需用户先在本机唤醒显示器并确认 Agent 能再次列出 display。
- 键鼠注入和 CLIPRDR 文本桥接已接线，但本轮尚未经真机验证；文件剪贴板未实现。
- 屏幕系统信息此前报告 2560×1664，而 ScreenCaptureKit 本次报告并捕获 1470×956；
  两种尺寸的对应关系需后续 Retina/缩放坐标实验确认，不把它们当作一致。

## 下一步

1. 在 Windows App 中验证键盘、鼠标移动/点击、Mac↔Windows 文本复制粘贴；输入测试请
   聚焦到空白文本编辑器，避免误操作其他应用。文件剪贴板仍需开发。
2. 核验控制台用户 UID + GeneratedUID 和会话 generation，确认快速用户切换时不泄露旧画面。
3. 注册当前登录用户的 LaunchAgent，自动维持采集；完善显示器变化和动态分辨率处理。

按当前范围，P0-B 登录窗口桥接已暂缓；未启用 Screen Sharing，也未执行锁屏、注销或重启。
