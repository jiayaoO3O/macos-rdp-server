# 诊断：RDP 键盘吞字 / 按键被当成修饰键组合（2026-11-08）

> 状态：**根因部分证实（结构性缺陷）、部分仍待真实会话 trace 证实（H1/H3）**。
> 本文件是现场 bug（"中文输入法打字时偶尔吞字，某个键像是被当成修饰键+键组合；
> 客户端侧无法恢复，但在 macOS 本机打一次字就恢复"）的诊断记录与采样指南。
>
> - 症状来源：2026-11-08 真机会话（Windows 11 `mstsc.exe` 全屏 → macOS 开发机）。
> - 相关代码：Worker 输入转发 `internal/worker/native.c`、Agent 输入注入
>   `native/macos/Sources/rdp-agent/main.swift` + `native/macos/Sources/MacAgentCore/MacKeyMap.swift`。
> - 本次改动引入纯逻辑状态机 `native/macos/Sources/MacAgentCore/KeyboardInputState.swift`
>   及其测试 `native/macos/Tests/MacAgentCoreTests/KeyboardInputStateTests.swift`。

## 0. 结论摘要（TL;DR）

1. **已证实的结构性缺陷（能直接造成"打字中按键突然被全部释放/吞字"）**：
   旧 Agent 在**每一条输入事件错误**（包括鼠标坐标映射失败、未知 scancode、载荷解码失败）
   的 catch 里调用 `releaseAll()`。真实日志里**单次会话出现 4859 次**
   `invalid_remote_mouse_coordinates`，每一次都会把当时按住的所有键（尤其 Shift/Cmd/Option）
   发 key-up。这是"按住修饰键/Shift 打拼音时字符被吞、组合键行为异常"的直接结构性原因。
2. **已证实的机制（能解释"只有中文输入法时出现"和"本机打一次字就恢复"）**：
   本机实验表明，Agent 用 `CGEvent(keyboardEventSource: nil, ...)` 注入的修饰键按下，
   **不会**更新 `CGEventSource.flagsState(.combinedSessionState)`，但会作为
   **flagsChanged 事件**投递到前台 App/输入法。丢失 modifier key-up 时，前台 App/IME 会
   保留"修饰键按下"的 flagsChanged 状态；本机真实键盘事件会刷新它（所以本机打字能恢复）。
   旧的 releaseAll 只释放"按虚拟键码记录"的集合，没有无条件修饰键清扫，也没有 SIGUSR1。
3. **已证实的小映射缺陷**：`E0 35`（小键盘 /）被错误映射为 `0x4c`（keypad Enter，应为
   `0x4b` kVK_ANSI_KeypadDivide）；小键盘数字/运算符、F13–F20、NumLock 缺失映射；
   `KBD_FLAGS_EXTENDED1 (0x0200)`（E1 前缀，Pause/Break）未处理，会被当成普通 `0x1d`
   注入一次 **Left Control 按下**。
4. **H1（卡修饰键）是当时最可能的主因；最终真机定案见 §9：直接根因是注入 CGEvent 继承陈旧 `maskSecondaryFn`（Fn）位，H1 的“客户端长按 Win 使后续按键变成 ⌘+字母”是同一现场的另一表现。** §6 的 trace 就是为了
   在一次真实复现里把它证实/排除。H3（unicode/IME 事件交互）同样只能靠 trace 区分。
5. 修复（默认打字行为不变，除默认开启一个保守安全网）：按 RDP scancode 身份记录按键 +
   release 时按另一扩展位回退；未知 scancode 只丢弃并限频记日志（**不再 releaseAll**）；
   鼠标映射失败只丢弃并限频记日志；补齐键位映射；所有终止/清理路径与 **SIGUSR1** 做
   **无条件修饰键清扫**；默认开启保守的"卡修饰键"保险（`RDP_AGENT_STUCK_MODIFIER_GUARD=0` 可关）；
   新增 opt-in 逐事件 trace（`RDP_AGENT_INPUT_TRACE=1` / `RDP_INPUT_TRACE=1`，默认关）。

## 1. 现场症状

- Windows 11 `mstsc.exe` 全屏，经局域网连 macOS（Apple Silicon 笔记本，内建屏约 2.9K，会话内虚拟
  16:9 显示器 2560x1440，Agent 以 `stream-snapshot` 持续采集）。
- **只在中文输入法（拼音）打字时**出现：偶发吞字；某个字母（用户举例 `d`）像是被解释成
  "某个修饰键 + d"（用户没看清具体组合，只确定不是普通字符输入）。
- 客户端侧（Windows）无法自行恢复；**在 macOS 本机键盘上打一次字后恢复正常**。

## 2. 输入链路与关键代码（本次诊断涉及的位置）

```
Windows mstsc (scancode / unicode 事件)
  -> Worker native.c keyboard()/unicode_keyboard()                          [1]
  -> Agent IPC type=3 (kind=2 scancode / kind=3 unicode / kind=4 releaseAll)
  -> Agent main.swift startInputReceiver -> AgentIPCCodec.decodeInputEvent
  -> AgentInputController -> CGEvent(keyboardEventSource: nil, ...).post(.cghidEventTap)
```

| 位置 | 说明 |
| --- | --- |
| `internal/worker/native.c` `keyboard()`/`unicode_keyboard()` | 只在 `ctx->leased && ctx->ready` 时转发；`!ready` 时静默丢弃（每个 peer 只记一次 `early_input_dropped`） |
| `internal/worker/native.c` peer 循环结束 | `ctx->leased` 时向 Agent 发 type 3 kind=4（release-all）；日志无逐事件细节 |
| `native/macos/Sources/rdp-agent/main.swift` `startInputReceiver` | 单条消息出错时旧实现 catch 里 `releaseAll()`（HEAD 8290219:1063/1072/1079） |
| `main.swift` `AgentInputController` | 旧实现按**映射后的虚拟键码**记录 pressedKeys；未知 scancode `throw`；`releaseAll()` 只释放已记录集合（HEAD:1958-1981） |
| `MacKeyMap.swift` | PC set1 -> macOS vkey；HEAD 版本小键盘映射缺失、`E0 35` 映射错误 |
| `AgentInputAudit.swift` | 每种输入 kind **每进程只记一次** `remote_input_received` —— 所以历史日志里没有逐键证据 |

## 3. 证据

> 日志为开发机本地未入库文件 `.runtime/agent-launchd.log`（约 37 MB）、
> `.runtime/worker-live.log`（约 485 MB）。行号/计数为 2026-11-08 20:00 左右快照，
> 复现命令见 §6。

| # | 证据 | 数据 | 对应代码/含义 |
| --- | --- | --- | --- |
| E1 | `event=remote_input_rejected` | 4863 次；其中 `error=invalid_remote_mouse_coordinates` **4859** 次，`error=unsupported_RDP_scancode_0x5b` 4 次（`agent-launchd.log:55042-55046`，旧版 Win 键映射缺失时期） | 旧 catch 每次都 `releaseAll()` |
| E2 | 4859 次鼠标坐标失败集中在**一个持续会话** | `agent-launchd.log:154542-160174`：4859 条 `invalid_remote_mouse_coordinates` + 765 条 `snapshot_timing`（每 30 帧一条）+ 8 条 display/virtual-display 事件；即平均每约 1.2 s 的 30 帧块约 6.3 次失败，持续约 13–17 分钟（按 `loop_ms` 约 35–45 估算） | 不是瞬时抖动；整段会话里**每一个鼠标事件**都把按住的所有键释放一次 |
| E3 | 鼠标映射失败的代码路径 | `DisplayCoordinateMapper.desktopPoint` 只有在 `CGDisplayBounds(displayID).width/height <= 0` 时返回 nil（`DisplayLayout.fit` 只拒绝非正尺寸，`capturePoint` 恒 clamp；会话内 `capture=2214x1440` 有效） | 捕获的显示器在会话中途变为 inactive/0 尺寸（显示排列或虚拟显示器切换）；**Follow-up 见 §9** |
| E4 | `event=early_input_dropped` | `.runtime/worker-live.log` 22 次，全部 `kind=key reason=session_not_ready`（如 364398、364441、368298 行，均在 lease/重连窗口） | `!ready` 窗口内 Worker 丢弃输入且**之后没有任何 resync**；若被丢的是 key-up，就会留下按下状态 |
| E5 | 旧 Agent 终止路径 | HEAD:397 在 `stream-snapshot` 正常结束后有 `releaseAll()`；但 `throw` 退出、诊断 `stream` 路径、`kill -9` 不覆盖；且旧 releaseAll 只发"记录集合" | 修正最初怀疑：**正常 SIGTERM 路径当时是会 release 的**；真正缺的是"无条件修饰键清扫"和异常/信号路径 |
| E6 | 历史日志里没有逐键证据 | `event=remote_input_received` 全文件仅 65 条（每进程每 kind 一条，见 AgentInputAudit） | 所以 H1 无法从现有日志证实——需要新增 trace（本次交付） |
| E7 | 键位映射缺陷（读代码确认） | HEAD `MacKeyMap.swift:7`：`case 0x35: return 0x4c // keypad divide` -> 实际是 keypad Enter；HEAD 非扩展分支缺 `0x37/0x45/0x47-0x53`（小键盘）与 `0x64-0x6b`（F13-F20） | 按小键盘 `/` 会发送 Enter；按小键盘其它键 `throw` -> 旧 catch `releaseAll` |
| E8 | E1 前缀键（Pause/Break） | FreeRDP `KBD_FLAGS_EXTENDED1=0x0200`（fastpath PREFIX_E1 映射而来）；HEAD 只判断 `0x0100`，于是 E1 1D 45 的 `0x1d` 被映射成 Left Control 按下 | Pause 会注入一次多余 Left Control（随后 E1 9D 才释放）；若 release 丢失则卡 Ctrl |
| E9 | 扩展位不一致的 key-up | HEAD 按"映射后 vkey"记录：`0x1c` 扩展=keypad Enter(0x4c)、非扩展=Return(0x24)；若 down/up 扩展位不同，旧实现会留下一个孤儿按键 | 本次改为按 `(scancode, extended)` 身份记录 + 反向扩展位回退释放 |

### 3.1 判定实验（H4，2026-11-08 本机实测）

在一个具有 Accessibility 权限的终端里编译运行了最小 Swift 程序（session event tap
listen-only + `CGEventSource.flagsState(.combinedSessionState)`），结果：

| 操作 | session 事件流看到 | `flagsState(.combinedSessionState)`（操作后） | 后续 nil-source key 事件的 flags |
| --- | --- | --- | --- |
| `CGEvent(keyboardEventSource: nil, virtualKey: 0x37 /*Cmd*/, keyDown: true)` | **type 12 flagsChanged，cmd=1** | **cmd=0（未变）** | cmd=0 |
| 同上但 source=`CGEventSource(stateID: .hidSystemState)` | type 12 flagsChanged，cmd=1 | **cmd=1** | cmd=1（被污染） |

结论（本机 macOS 27.2 实测，非推断）：

- Agent 现有的 **nil-source 注入方式会把 modifier 按下/抬起以 flagsChanged 交给前台 App/IME**，
  但**不会**改 WindowServer combined 状态；因此**孤儿 modifier 是留在 App/IME 的 flagsChanged
  层**，不是"所有后续事件都带 Cmd flags"。这与"只有输入法受影响、本机打字（真实硬件
  flagsChanged）能清掉"一致。
- 反过来说：**不要**改成 `.hidSystemState` 源或给每个事件显式设 flags——实测那会让孤儿
  modifier 污染后续每一个按键（更糟）。
- 推论：**无条件修饰键 key-up 清扫**（即使 press table 认为没按下）会产生 flagsChanged=0 的
  清除事件，正是"本机打一次字"的等价修复；而 `flagsState` trace 若显示 `sys=cmd:0` 也
  **不能**排除 App/IME 层的卡住，必须同时看 Agent 自己的 pressed table（trace 已同时记录）。

## 4. 假设判定

| 假设 | 判定 | 依据 | 剩余验证 |
| --- | --- | --- | --- |
| **H1** 某个 modifier 卡在 WindowServer/App 层，后续字母被当成组合键 | **最可能，未证实（需真实 trace）** | 现场"只有中文输入法 + 本机打字恢复"与 nil-source flagsChanged 机制（§3.1）吻合；E4/E8/E9 提供 key-up 丢失路径 | 下一次真实会话 trace：Worker/Agent 是否出现"Win keydown 无 keyup"或 `input_trace_dropped` |
| H1(a) Windows 本地热键/IME 切换键（Win+Space、Ctrl+Space、Shift 等）只转发 keydown | **疑似（未证实）** | 机制成立；本项目 Win 键映射为 Command（`MacKeyMap` 0x5b/0x5c -> 0x37/0x36），卡住正好表现为 Cmd+字母 | Worker trace 里 `flags=0x0100 code=0x5b down=1` 之后没有对应 `flags=0x8100 code=0x5b` |
| H1(b) Worker 在 `!ready` 窗口丢弃 key-up | **已证实存在，频率低（22 次/整日志）** | E4；无 resync | trace 里症状时刻是否正好有 `input_trace_dropped` |
| H1(c) Agent 重启/退出时 modifier 仍按下 | **部分证实**：正常 SIGTERM 会释放，但异常 `throw`/诊断路径不释放且无无条件清扫 | E5 | 修复已覆盖所有终止路径 + SIGUSR1 |
| H1(d) 客户端 down/up 扩展位不一致 | **已证实代码缺陷**（E9），已修 | 读代码 | 真实 trace 可观察 |
| **H2** 逐事件错误就 releaseAll / 未知 scancode 常见 | **已证实（结构性，含真实日志量级）** | E1/E2/E3/E7；旧代码 HEAD:1063/1970 组合 | 无需 trace：修复后同类事件只丢弃并限频记录 |
| **H3** unicode 与 scancode 事件交互（输入法提交文本） | **未证实（需 trace 区分）** | 现有日志只记 kind 不记 code；Windows IME 可能提交 unicode 事件与 scancode 交错 | 新 trace 保留 kind/flags（unicode 不记 code），可看时序与 down/up 配对 |
| **H4** 注入事件 flags 语义异常 | **已证实并已按结论处理**（§3.1） | 本机实验 | 真实会话只需观察 flagsState 与 pressed table 的一致性 |

## 5. 本次修复

### 5.1 纯逻辑（可测，`MacAgentCore`）

- 新增 `KeyboardInputState`（`KeyboardInputState.swift`）：
  - 按 `(scancode, extended, extended1)` 身份记录按键；**release 找不到精确身份时按另一扩展位
    回退释放**（E9）；未记录的 key-up 也照常投递（无害的 resync）；
  - 未知/不可映射 scancode **返回"拒绝"而不是 throw**，首次出现记一次
    `event=input_rejected reason=unsupported_scancode code=... ext=...`，其它按键状态不变；
  - `KBD_FLAGS_EXTENDED1 (0x0200)` 整族丢弃（E1 前缀，Pause/Break），避免注入多余 Left Control；
  - `releaseAll()`：释放全部已记录键/unicode/鼠标键后，**无条件**对 9 个 modifier
    （左右 Cmd/Option/Control/Shift + CapsLock）各发一次 key-up（已释放的不重复）；
  - 保守"卡修饰键"保险（见 §5.3）；
  - `InputTraceFormatter` / `RateLimitedLogGate` / `InputTraceFeatureGate`。
- `MacKeyMap` 补齐并修正：
  - 修复 `E0 35`：keypad divide -> `0x4b`（原先 `0x4c` = keypad Enter）；
  - 小键盘 `0x37,0x47-0x53`、`0x4a/0x4e`、NumLock(0x45 -> keypad clear 0x47)、F13–F20；
  - PrintScreen/ScrollLock/SysRq/Help/Menu/Power/Sleep/F21-F24 明确"故意不映射"
    （`isDeliberatelyUnmapped`），丢弃但不抛错、不影响其它键；
  - Win 键两种扩展位都接受（0x5b/0x5c -> 0x37/0x36）。
- 测试 `KeyboardInputStateTests`（无 GUI/TCC）：全表 down/up round-trip、非扩展映射单射、
  Win 键两族一致、小键盘/F13-F20 断言（含 0x35 与 0x1c 的区分）、故意不映射断言、
  扩展位翻转释放、未知 scancode 不扰动其它键、EXTENDED1 不注入修饰键、重复 keydown 幂等、
  未记录 key-up resync、releaseAll 无条件清扫且幂等、保险阈值/可关闭/不含 Shift/Caps/
  不受自动重复影响/释放后重新计时、trace 格式（unicode 不出现 `code=0x`）、限频日志。

### 5.2 Agent 薄适配层（`main.swift`，仅 INPUT 段）

- `AgentInputController` 只做 CGEvent 投递 + 日志；状态/判定全部在 `KeyboardInputState`；
  用 `NSLock` 串行化（socket receiver、SIGUSR1、teardown 三个来源）。
- **逐事件错误不再 releaseAll**：未知 scancode 丢弃+首次记日志；解码失败/鼠标坐标失败
  丢弃+限频
  `event=remote_input_dropped reason=invalid_payload|invalid_coordinates display_bounds=WxH display_id=N desktop=WxH capture=WxH suppressed=N`
  （只记数字尺寸/ID，不记路径与文本）。
- `releaseAll(reason:)` 只保留给真正的清理路径：Worker release-all（`peer_release_all`）、
  socket 关闭（`socket_closed`）、接收线程不可恢复错误（`input_receiver_error`）、
  SIGUSR1（`signal`）、进程终止（`termination`，用 `defer` 覆盖 `throw` 退出）。
- `streamSnapshot` 注册 `defer { inputController.releaseAll(reason: "termination") }`；
  新增 `InputSignalSweep`（`DispatchSourceSignal(SIGUSR1)` + 独立串行队列，经同一加锁输入路径）。
- 默认审计日志不变：每种 kind 每进程一行 `event=remote_input_received`，不记键码/文本。

### 5.3 "卡修饰键"保险（默认开启，env 可关）

- 触发条件（全部满足）：Agent 自己记录为按下的 **Cmd/Option/Control**（不含 Shift/Caps）
  已按住不少于 **10 000 ms**，且期间收到不少于 **12** 个**新的**非修饰键 key-down
  （自动重复不计入），且没有收到该修饰键的 key-up。
- 动作：post 该修饰键 key-up，记
  `event=input_stuck_modifier_released key=0x37 role=command held_ms=12345 events_since=13 sys=...`。
- 误报风险：需要"按住 Cmd/Option/Ctrl 超过 10 秒、其间逐键输入 12 个不同键"。真实快捷键
  组合远达不到（长按修饰键组合通常是 1–3 个键）。最坏后果只是修饰键被提前释放，用户再按即可。
- 关闭方式：`RDP_AGENT_STUCK_MODIFIER_GUARD=0`。
- 只在我们自己记录到 key-down 时才释放；`flagsState` 显示"系统按下但我们从未按下"时**不动**
  （可能是本机物理按键/其它进程，避免干扰）。

### 5.4 Worker opt-in trace（`native.c`，默认关）

`RDP_INPUT_TRACE=1` 时（仅隔离测试/维护者授权的诊断会话）：
- 转发：`event=input_trace kind=key flags=0x%04x code=0x%02x`
- `!ready` 或写失败丢弃：`event=input_trace_dropped kind=key reason=... flags=... code=...`
- unicode：**只记 flags**，绝不记 code（用户文本）：
  `event=input_trace kind=unicode flags=...` / `event=input_trace_dropped kind=unicode ...`
- 现有 `early_input_dropped` / `agent_input_dropped` 事件名与语义未改，默认行为不变。

## 6. 真实会话采样指南（给维护者/评审者）

> 隐私提示：trace 含**按键码**（物理键位；unicode 只含 flags，不含字符）。只在诊断会话短时开启，
> 采样文件放 `/tmp`，分析完删除，不要提交/外传。

前置：需要部署本次改动的 Worker + Agent（**由维护者决定并成对部署**；
本文档不执行部署，也不覆盖 `bin/`）。

1) Worker（会断当前会话，需维护者确认后按 AGENTS §6.3 流程重启）启动环境变量：
```sh
RDP_INPUT_TRACE=1 nohup ./bin/rdp-worker -config .runtime/config.json \
  -agent-socket .runtime/agent-compat.sock >> .runtime/worker-live.log 2>&1 &
```
   （已运行的会话需要重启 Worker 才生效；不想动 Worker 也可先只看 Agent 侧 trace。）

2) Agent（不断 RDP 会话）：在 LaunchAgent wrapper 环境里加 `RDP_AGENT_INPUT_TRACE=1`
   （可选：加 `RDP_AGENT_STUCK_MODIFIER_GUARD=0` 只看不释放），然后
   `launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent`。

3) 记录采样起点：
```sh
wc -l .runtime/agent-launchd.log .runtime/worker-live.log | tee /tmp/input-trace-mark.txt
```

4) 复现：Windows 上连入（全屏），用**中文输入法**正常打字，尽量触发问题；
   如果出现吞字/异常组合键，**记下大致时间**并继续打几个字，然后断开或停止采集。

5) 采集窗口（Agent 行无时间戳，用行号起点；Worker 里 Go 行有时间戳可用时间对齐）：
```sh
awk -v m="$(awk '/agent-launchd/{print $1}' /tmp/input-trace-mark.txt)" \
  'NR>m && /event=(input_trace|input_trace_dropped|input_release_all|input_rejected|input_stuck_modifier_released|remote_input_dropped)/' \
  .runtime/agent-launchd.log > /tmp/input-agent-window.log
tail -n 20000 .runtime/worker-live.log > /tmp/input-worker-window.log
```

6) 判读（按 H1/H3）：

| 观察 | 指向 |
| --- | --- |
| Worker trace：`code=0x5b/0x5c`（Win 键）或 `0x1d/0x38`（Ctrl/Alt）出现 `flags=0x0100/0x0000 down=1`（或带 0x0200 前缀）但后面**没有**对应的 `flags=0x8100 ... down=0` | **H1(a)**：客户端没发 key-up（本地热键/输入法切换吃掉） |
| Agent trace：某 modifier 的 `pressed_keys` 一直大于等于 1，后续字母 `down=1` 但无该 modifier 的 `down=0`；且 `sys=` 显示 `cmd:0` | 孤儿 modifier 在 App/IME flagsChanged 层（§3.1）；`input_stuck_modifier_released` 应随后出现并恢复 |
| Agent trace：`sys=cmd:1/ctrl:1/opt:1` 但 Agent 从未按下该修饰键 | 本机物理按键/其它进程状态，**不要**自动干涉（guard 不会动） |
| Worker trace：症状时刻出现 `event=input_trace_dropped kind=key reason=session_not_ready flags=0x8100 ...` | **H1(b)**：重连窗口丢了 key-up |
| Agent trace：中文输入法打字时同时出现密集 `kind=unicode` 与 `kind=scancode`，或 unicode down/up 不配对、顺序与 scancode 交错 | **H3**：unicode/scancode 交互，需进一步设计 |
| Agent trace：`event=remote_input_dropped reason=invalid_coordinates display_bounds=0x0 ...` | 鼠标路径 display 失效（§9 Follow-up），与打字释放无关（现在不再 releaseAll） |

7) 结束后删除：`rm -f /tmp/input-*-window.log /tmp/input-trace-mark.txt`。

**临时恢复手段（无需重启）**：本次改动后 macOS 菜单栏 App 会有"释放卡住按键"按钮，它向
Agent 发 **SIGUSR1**；也可以手动：
```sh
kill -USR1 "$(pgrep -f 'RDPAgent.app/Contents/MacOS/rdp-agent stream-snapshot' | head -1)"
```
预期 Agent 日志出现 `event=input_release_all reason=signal ... swept=9`，采集不中断、进程不退出。

> **2026-11-09 更新（历史记录）**：键盘根因修复并真机验收后，手动「释放卡住按键」按钮及 Agent 侧 SIGUSR1
> handler 已移除；自动释放路径（peer release-all / socket close / receiver error / termination）保留。
> 下面 §7、§8 保留为当时的实现与契约记录，不再描述当前行为。

## 7. 客户端侧临时规避（不依赖服务端改动）

- `.rdp` 文件里设置 `keyboardhook:i:1`（"应用 Windows 键组合"= 发送到远程计算机），
  让 mstsc 尽量把组合键转发而不是本地处理；默认全屏模式可能仍本地处理部分组合。
- **避免用 `Win+Space` 切换 Windows 输入法**（Windows 11 默认热键）：在 RDP 全屏里按它会
  产生本机 shell 与远程的状态分歧，正是 H1(a) 的典型触发。改用任务栏语言栏点击、
  `Ctrl+Space`/`Alt+Shift`（取决于本机设置）或先切好输入法再进入 RDP。
- 同理避免在 RDP 焦点下按 `Win+L`/`Win+D`/`Win+Tab` 等本机保留组合；按住 Shift/Ctrl
  切换输入法后确认已松开再继续打字。
- 若已经出现异常，用上面的 SIGUSR1（菜单栏按钮）或按一次本机真实修饰键/在 Mac 上打一个字
  即可恢复；之后服务端保险也会在满足阈值时自动释放。

## 8. SIGUSR1 语义（写进契约）

> **2026-11-09 更新（历史记录）**：该 SIGUSR1 手动恢复通道已随按钮移除；当前 Agent 只在
> 断线/接收错误/退出等自动路径调用 `releaseAll(reason:)`。本节仅记录当时的契约设计。

- `SIGUSR1` = **释放卡住按键**（菜单栏 App 按钮触发）：Agent 在独立串行队列上执行与
  socket receiver 相同的加锁输入路径，post 全部已记录键的 key-up + 无条件 9 个 modifier
  key-up，记录 `event=input_release_all reason=signal pressed_keys=... pressed_unicode=... swept=9`
  （trace 开启时附 `sys=...`），**不停止采集、不退出进程、不影响 socket**。
- 与 `releaseAll(reason:)` 其它 reason 的区别仅在日志 reason：`peer_release_all`（Worker 断开）、
  `socket_closed`、`input_receiver_error`、`termination`（defer 覆盖所有退出路径）、`signal`。
- **契约稳定性**：`event=input_release_all` 事件名是跨组件契约（菜单栏 App 的能力探测按该字符串
  判断 Agent 是否支持 SIGUSR1），只允许追加字段、不允许重命名。
- **SIGUSR1 处理器只在 `stream-snapshot`（生产采集模式）路径注册**；`virtual-display` 子进程是
  同一二进制的另一个子命令，**没有** SIGUSR1 处理器，不要向它发该信号（默认动作会终止它）。
  进程启动到处理器注册完成之间有极小窗口：菜单栏 App 只应向"自己拉起并确认在跑
  stream-snapshot"的 Agent PID 发送。

## 9. 未验证 / 待确认 / Follow-up

**未验证（本机无法自动验证）**

- H1 的直接证据：真实 Windows 客户端 + 中文输入法会话的 trace **尚未采集**；本文对 H1 的
  判定是"机制成立 + 现场行为吻合"，不是"已证实"。
- 卡修饰键保险在真实会话里的效果与阈值是否合适（10 s / 12 keys）未实测。
- macOS 输入法对孤儿 flagsChanged 的具体反应（是否真的把 `d` 当 Cmd+D、如何吞字）
  未在 IME 层面验证；SIGUSR1/guard 的恢复效果同样待真实会话确认。
- `keyboardhook:i:1` 对实际 mstsc 版本的效果、以及被吞 key-up 的具体组合键未实测。

**Follow-up（本任务范围外，建议单列）**

1. **捕获显示器 bounds 变为 0（E2/E3）**：会话中途 `CGDisplayBounds(displayID)` 变成
   0x0（显示排列/虚拟显示器切换），导致持续十几分钟鼠标映射失败。本次只把它变成
   "丢弃 + 限频记录 `display_bounds/display_id/desktop/capture`"，**没有改 display/虚拟显示器
   逻辑**；下一次真实会话即可用这些字段定位是虚拟显示器 teardown/mirror 还是显示休眠。
   之后应由 display/virtual-display 负责人修复（例如捕获期间遇到 0 bounds 时重取 SCDisplay /
   重建 filter）。
2. **Worker `!ready` 窗口输入丢弃无 resync**（E4）：可考虑"ready 后向 Agent 发 type 3 kind=4
   做一次释放清扫"，或对 key-release 事件在窗口内也转发。属于 Worker 输入路径语义变更，
   本次未做（避免改变既有重连行为）；trace 可给出该窗口的实际频率。
3. **unicode/scancode 双路径**（H3）：若 trace 证实输入法提交同时产生 unicode 与 scancode 事件，
   需要讨论去重/顺序策略（本任务只提供可区分两者的 trace）。
4. C 侧日志无时间戳（跨文件对齐困难）：本次 trace 也未引入时间戳（保持既有格式）；
   若后续长期需要，可考虑给 `event=input_trace` 行加单调毫秒字段（append-only）。
5. `make agent-check` 的手写 swiftc 清单需要维护者同步新增的两个文件
   （见最终报告），否则新测试不会进默认套件。
6. 菜单栏 App 目前用"二进制里是否存在 `input_release_all` 字符串"来探测 SIGUSR1 能力
   （见 §8 契约稳定性）；更干净的长期方案是 Agent 提供显式 `capabilities` 子命令输出版本/能力行。
   本次未实现（避免扩大 CLI 契约），如需要可在后续任务加。

## 10. 本次测试命令（供复核）

```sh
# 1) Swift 纯逻辑（等价 make agent-check，多两个新文件）
swiftc native/macos/Sources/MacAgentCore/{PermissionSnapshot,CaptureProgress,AgentStreamDuration,AgentInputAudit,CaptureExclusion,DisplayCoordinateMapper,DisplayModeMatcher,AgentIPCMessage,ClipboardFileTransfer,ClipboardFileStaging,AgentFrameAssembler,AgentUnixSocket,MacKeyMap,DisplayPixelSize,SnapshotPacing,CaptureTiming,CaptureSizeRequest,CaptureGeometry,DisplayLayout,CapturePixelConverter,AgentFrameDeltaEncoder,VirtualDisplaySession,KeyboardInputState}.swift \
  native/macos/Tests/MacAgentCoreTests/{PermissionSnapshotTests,DisplayModeTests,ClipboardFileTransferTests,VirtualDisplayTests,KeyboardInputStateTests}.swift \
  -o native/macos/.build/permission-tests && native/macos/.build/permission-tests

# 2) Swift 构建
swift build --package-path native/macos   # (或 -c release)

# 3) Unix socket wire harness（CORE_FILES 已加入 MacKeyMap/KeyboardInputState）
python3 scripts/test-agent-ipc-wire.py

# 4) 隔离 loopback E2E（不覆盖 bin/）：构建到 /tmp + 新断言 test_21c（teardown release-all）
mkdir -p /tmp/rdp-check && go build -o /tmp/rdp-check/ ./cmd/...
RDP_TEST_WORKER_BINARY=/tmp/rdp-check/rdp-worker RDP_TEST_PROBE_BINARY=/tmp/rdp-check/rdp-probe \
  python3 scripts/test-protocol.py
```

新增/修改的回归测试重点：

- `KeyboardInputStateTests`：映射完整性/round-trip（含 `0x35(ext)->0x4b` 与 `0x1c(ext)->0x4c`
  必须不同）、扩展位翻转释放、未知 scancode 不 releaseAll、EXTENDED1 不注入 Ctrl、
  releaseAll 无条件 modifier 清扫、保险阈值与误报边界、trace 隐私（unicode 无 code）、限频。
- `scripts/test-protocol.py::test_21c_release_all_on_peer_teardown`：真实 Worker 在 RDP peer
  断开时向 fake Agent 发送 type 3 kind=4（保证 Agent 的终止清扫有端到端通路）。

---

## 9. 根因定案（2026-11-08 晚，event-tap 实证）

**症状**：真实 Windows 11 客户端 + 中文输入法打字时，普通 `e` 被 macOS 当成 **Fn+E**，
弹出「表情与符号」字符检视器（CharacterPalette）；且 `Win+C` 一次之后必现，
退出面板后继续按 `e` 仍会被吞/弹面板。

**证据链**：

1. 统一日志（`log show`）显示面板由焦点 App（VS Code / Edge / DeepSeek Harness）通过
   `TSMLaunchCharacterPalette` 拉起；用辅助功能读取这些 App 的 Edit 菜单，菜单项为
   `表情与符号 | char=E | mods=24`。AX 的 `mods` 位定义中 `24 = 8(无 Command) | 16(Fn)`，
   即该快捷键是 **Fn+E**（不是输入法、也不是 ⌃⌘Space）。
2. 在 Agent 内加入**会话级 CGEventTap 探针**（`RDP_AGENT_EVENT_TAP=1`，仅监听），
   记录 WindowServer 实际交付给 App 的 `event.flags`。复现时的关键序列：

   ```
   ts=…66419 event=input_trace code=0x5b down=1        # 客户端发 Win 按下（映射 Command）
   ts=…66420 TAP flagsChanged code=0x37 flags=0x20b00008
   ts=…66534 TAP keyDown      code=0x08 flags=0x20b00008  # C 键：Command ✓（复制正常）
   ts=…68979 event=input_trace code=0x12 down=1        # 普通 e 按下
   ts=…68985 TAP keyDown      code=0x0e flags=0x20a00000  # e 键：含 0x800000 = Fn！
   → CharacterPalette 在 22:44:29 被拉起
   ```

   修复前 `e` 的 flags 含 `maskSecondaryFn`；修复后同序列 `e` 的 flags 只剩真实修饰键位
   （无 Fn，无 NumericPad），面板不再出现。
3. 本地可复现：用 fake Worker 向真实 Agent 发送 `F5 → e`（或 `Win+C → e`），
   修复前 `e` 的注入 flags 为 `0x20800100`（含 Fn）且 CharacterPalette 立即被拉起；
   修复后为 `0x20000000` 且无面板。`Win+C` 仍带 `maskCommand`，Shift+字母、Ctrl+Space
   的 flags 也验证正确。

**根因**：注入使用 `CGEvent(keyboardEventSource: nil, …)`。nil source 的 CGEvent 会**继承**
source 当前的 flags；功能键/方向键/Win 组合键会让事件带上 `maskSecondaryFn`（Fn）位，
该位随后**粘在后续注入事件上**，于是普通字母被 App 解释为 Fn+字母（Fn+E = Emoji & Symbols）。
之前针对 Win 键的一次性释放、修饰键重同步等防御没有触及这一层，所以症状持续。

**修复（Agent）**：

- 每个注入的键事件都**显式设置 `event.flags`**，只由当前真正注入按下的
  Cmd/Option/Control/Shift/Caps 计算（`KeyboardModifierFlags.from(pressedVirtualKeys:)` +
  `cgEventFlagsRawValue`，纯逻辑在 MacAgentCore 中可单测），从源头隔离 Fn/NumericPad 等
  device bits；unicode 注入事件同样处理。
- 配套：Win 键「一次按压只算一个组合键」（首个键后立即释放 Command，防止客户端长按 Win 把
  后续打字变成 ⌘+字母）、Win+Space 变普通空格、迟到/重复 Win 事件吞掉、每个普通键按下前
  清扫未被客户端按住的 Cmd/Opt/Ctrl。
- 回归测试：`KeyboardInputStateTests` 新增 Fn/NumericPad 永不出现在显式 flags 的断言；
  `RDP_AGENT_EVENT_TAP=1` 保留为诊断开关（默认关，只记录键码与 flags，不记录文本）。

**遗留**：真实 Windows 客户端上 mac→win 文本剪贴板粘贴失败（win→mac 文本与文件均成功），
见 [STATUS-2026-11-08.md](STATUS-2026-11-08.md) §1 与本文 §9。

