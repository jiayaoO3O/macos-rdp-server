# DESIGN-2026-11-08 自定义 16:9 虚拟显示器（消除 RDP 左右黑边）

> 关联设计：自定义 16:9 显示模式用于 RDP 采集。
> 状态：**代码已落地，默认关闭（`RDP_AGENT_VIRTUAL_DISPLAY=1` 开启）**；macOS 27.x 实测通过，
> 真实 Windows App + 物理面板观感待现场验收（见 §8）。
> 相关：`docs/DESIGN-2026-11-07-resolution-adaptation.md`（fit-with-bars / 鼠标坐标契约）。

## 1. 背景与目标

Windows App 以 16:9 桌面框（例如 2560x1440）连接时，物理面板是 2940x1912（约 1.537:1）。
Agent 在原生分辨率下采集 2214x1440 交给 Worker，Worker 按 fit-with-bars 合成到 2560x1440 桌面框，
左右各出现约 173px 黑边。设计选择：**创建自定义 16:9 显示模式/虚拟显示器，让采集正好等于桌面框，
彻底去掉黑边**（物理面板被 letterbox 可以接受，用户只看 RDP 画面）。

已有方案（切换到接近比例的真实 display mode）会让 macOS 对物理面板 letterbox 并且
切换/恢复期间采集尺寸抖动；代码默认开启 auto mode matching，可用 `RDP_AGENT_MATCH_DISPLAY_MODE=0` 关闭（虚拟显示器路径下该匹配不生效）。
私有 `CGDisplayModeCreate` 的 24 个字典键在 macOS 27.2 上无法在时间盒内恢复（CoreDisplay 只在
dyld shared cache 中、键值语义未知），因此采用下文的虚拟显示器方案。

## 2. 方案

### 2.1 总体结构

```
Agent (rdp-agent, 常驻)
  └─ 首次收到 IPC type 9（协商桌面框 WxH）且 RDP_AGENT_VIRTUAL_DISPLAY=1
       └─ spawn 子进程: rdp-agent virtual-display --width W --height H
            ├─ 私有 CGVirtualDisplay* 类创建虚拟显示器（1x，pixels == points == WxH）
            ├─ 公开 CG 显示配置 API 把物理显示器 mirror 到虚拟显示器上
            ├─ stdout 打印唯一握手行: display_id=<id> width=W height=H
            └─ 阻塞读 stdin；stdin EOF / SIGTERM / SIGINT / SIGHUP → 解除 mirror 并退出
       └─ 父进程读到 display_id 后：**不改采集目标**，仅记录 ready 延迟
  └─ IPC type 17 / socket EOF / 进程退出 → 父进程关闭子进程 stdin → 子进程恢复显示排列
```

### 2.2 关键结论：不需要重绑采集（本机 macOS 27.2 实测）

物理显示器 mirror 到虚拟显示器后：

- `CGDisplayCopyDisplayMode(physical)` 报告 2560x1440，`CGDisplayBounds(physical)` 为 2560x1440 points，
  因此现有 `DisplaySizeMonitor`（轮询被捕获的物理 displayID）自动把 geometry 更新为
  `native=2560x1440 desktop=2560x1440 capture=2560x1440 policy=exact`；
- Agent 启动时缓存的物理显示器 `SCContentFilter` **继续可用**：`SCScreenshotManager` /
  `SCStream` 用该 filter 请求 2560x1440 时返回虚拟显示器的共享 framebuffer（实测 2560x1440 BGRA，
  像素与直接采集虚拟显示器一致，无上下黑边；背景行亮度 profile 一致）；
- mirror 期间新建 `SCShareableContent` 只列出虚拟显示器（物理显示器不可见），因此**不要在会话中途
  重新解析 SCShareableContent**；Agent 只在启动时解析一次，满足该约束；
- 解除 mirror 后缓存 filter 继续返回物理显示器的新画面（实测 capture 回到 2214x1440 fit）。

结论：集成只需子进程生命周期 + feature gate + 状态机，**不修改** `CaptureGeometry`、
`DisplaySizeMonitor`、`DisplayCoordinateMapper`、输入 displayID 或 fit-with-bars 契约。
1x 虚拟显示器上桌面坐标、采集像素、显示 points 三者相同，鼠标映射按现有整数运算自然退化为恒等
（`DisplayLayout.isOneToOne`，Swift 测试覆盖）。

**该 mirror framebuffer 行为是系统实现细节，仅在 macOS 27.x 验证**；换系统版本需重跑 §8 的
integration harness（若行为变化，会表现为采集尺寸仍为 fit/黑边或 SCK 报错，feature gate 可立即回滚）。

> **2026-11-09 更正（真机）：** 上面“输入 displayID 不需要修改”的结论只在 macOS 27.2 成立。macOS 26.5.1 的 mirror
> 会保留物理屏原生 HiDPI **points**，而 capture 是虚拟屏的像素尺寸（例如物理 2560x1440 points、capture 3840x2160），
> 继续用物理屏 `CGDisplayBounds` 换算会把注入坐标乘 points/pixels，表现为鼠标左上对齐、越往右下偏移越大（视频/帧率正常）。
> 修复：输入 target 在虚拟屏 active 且 bounds==capture 时改用虚拟屏 displayID/bounds，否则回退物理屏（commit `e13c9d3`）；
> 采集/geometry 不需要重绑的结论不变。macOS 27.2 上两者相等，行为与修复前一致。详见
> [DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md](DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md)。

### 2.3 现场重连缺陷修复（2026-11-08 fix round）

现场真机 mstsc 连续重连（2560x1440 → 1920x1080 → 2560x1440…）时，Session C 之后
`virtual_display_spawn result=1 stage=ready_timeout`，物理面板被留在 1920x1080。根因与修复：

0. **根因（本机复现确认）**：WindowServer 按虚拟显示器 identity（vendor/product/serial）持久化上次使用
   的 mode；原实现固定 identity（0x1234/0x5678/serial 1），Session B（1920x1080）把该 identity 的
   "记忆 mode" 写成 1920x1080，之后所有 2560x1440 会话创建出来的虚拟显示器都默认 1920x1080、size check
   超时。修复：每次 spawn 使用**随机 product + serial**（name 固定 "RDP 16:9"），identity 永远是新的，
   请求的 mode 生效；日志 `virtual_display_child_identity product=0x.. serial=..`。
   另外 Swift 子进程必须 **pump 主 run loop**，否则 `CGVirtualDisplay.applySettings` 的 mode 应用
   block 不执行（会停在 WindowServer 默认 1920x1080）；创建/注册/mode/mirror 等待循环均已改为
   `CFRunLoopRunInMode` 驱动。短命进程用裸 `CGDisplaySetDisplayMode` 设置的模式会在进程退出后回滚，
   故 mode 设置统一改为 `CGBeginDisplayConfiguration + CGConfigureDisplayWithDisplayMode +
   CGCompleteDisplayConfiguration(.forSession)` 事务（父进程、子进程、`set-display-mode` 工具共用）。
1. **父进程不再假设每次 mirror 都从 native 模式开始**：Agent 在 `streamSnapshot` 启动时记录物理面板
   pixel size（`startupPhysicalPixels`），每次 spawn 子进程时通过
   `--restore-physical WxH --physical-display <id>` 传入；子进程创建虚拟显示器之前先把物理面板显式
   设置回该模式（display config 事务，2s 验证），失败则直接失败、不 mirror。
2. **子进程显式保存/恢复物理模式**：mirror 之前保存 `CGDisplayCopyDisplayMode(physical)` 快照，teardown
   或 setup 失败时先解除 mirror，再 `CGDisplaySetDisplayMode` 恢复快照并验证像素尺寸；日志
   `virtual_display_child_mode_saved/restored saved=WxH current=WxH`。
3. **失败可观测**：父进程把子进程 stderr 逐行转发为 `event=virtual_display_child_stderr line=...`
   （此前子进程 stderr 未捕获，`size_check` 失败在父日志里不可见）。
4. **失败安全网 + 单次重试**：ready_timeout / handshake / launch 失败后父进程强制恢复启动模式
   （`event=virtual_display_physical_restore`），500ms 后重试一次（`event=virtual_display_retry attempt=1`，
   policy 增加纯逻辑 `.retry` 事件）；再失败则保持 fit-with-bars 并记录 `display_state_after`。
5. **会话结束兜底**：type 17 / EOF / agent exit / session_end 均验证并恢复启动模式。
6. **防"虚拟套虚拟"**：父进程 spawn 前要求存在可用 mirror target（`CGDisplayIsBuiltin==1 && active`
   的内置屏，或 active 且非 virtual 的外接屏；见 `DisplayModeHelper.mirrorTargets/isUsableMirrorTarget`），
   否则 `event=virtual_display_skipped reason=no_physical_display`，保持 fit-with-bars；子进程也按
   `--physical-display` 校验并记录 `event=virtual_display_child_target`；WindowServer 的
   "unkn"/"virt" 遗留虚拟显示器一律拒绝。
7. **启动诊断**：Agent 启动时打印 `event=display_inventory online=... id=.. builtin=.. active=.. main=..
   pixels=.. points=.. vendor=0x.. model=0x..`，若 main display 是 virtual 则告警
   `event=main_display_virtual result=1`。
8. **ready 超时从 5s 提高到 8s**，并用 spawn generation 防止上一会话的 stale timeout 误杀新 child
   （多会话 harness 曾复现该竞态）。
9. **ready 超时后的单次重试与 physical mode 恢复**（见上）。

## 3. 组件

| 文件 | 职责 |
| --- | --- |
| `native/macos/Sources/MacAgentCore/VirtualDisplaySession.swift` | 纯逻辑：`RDP_AGENT_VIRTUAL_DISPLAY` 解析（仅字面 `1` 开启）、尺寸校验、子进程 stdout 握手行解析、会话状态机（首 type 9 spawn / 后续 type 9 只记 `resize_ignored` / type 17·EOF·exit 收尾 / 失败态不重试） |
| `native/macos/Sources/rdp-agent/VirtualDisplayChild.swift` | 子进程：CoreGraphics 私有 `CGVirtualDisplayDescriptor/CGVirtualDisplay/CGVirtualDisplaySettings/CGVirtualDisplayMode`（`NSClassFromString` + `objc_msgSend` IMP 桥接）；公开 `CGBeginDisplayConfiguration/CGConfigureDisplayMirrorOfDisplay/CGCompleteDisplayConfiguration` mirror；先强制 startup 物理模式再 mirror；保存/显式恢复物理 `CGDisplayMode`；拒绝离线/虚拟 physical display；stdout 握手；stdin EOF / 信号恢复 |
| `native/macos/Sources/rdp-agent/VirtualDisplayController.swift` | 父进程：spawn（传 `--physical-display`/`--restore-physical`）/读 stdout 握手（8s 超时）/转发子进程 stderr/ready 延迟日志/意外退出监控/失败后恢复+单次重试/teardown（关闭 stdin → SIGTERM ≤2s → SIGKILL）/`display_state_before`·`after` 每会话一次 |
| `native/macos/Sources/rdp-agent/main.swift` | feature gate、`virtual-display` 子命令入口（不请求 TCC）、type 9/17/EOF/退出接线 |
| `native/macos/Tests/MacAgentCoreTests/VirtualDisplayTests.swift` | 纯逻辑测试：gate、握手解析、状态机全路径、1x 恒等坐标/`policy=exact` |
| `scripts/test-virtual-display-integration.py` + `make test-virtual-display` | headless 集成 harness：假 Worker socket（type 9/17）驱动真实 `stream-snapshot`，断言 display_id、SCK 2560x1440、采集帧 2560x1440、默认关闭回归、SIGTERM 恢复、部署版 SCStream+delta 路径无 fallback、**多会话连续重连 2560→1920→2560 且每次 teardown 后回 native**、**Agent 启动后面板被改为 1920x1080 时下一次会话仍能恢复 native 并成功**；含 `set-display-mode` 诊断子命令 |

## 4. 日志事件（`event=snake_case`，只追加字段）

```
event=capture_config ... virtual_display=0|1
event=virtual_display_spawn result=0 width=W height=H pid=N executable=<abs path>
event=virtual_display_ready result=0 ms=N display_id=ID width=W height=H
event=virtual_display_resize_ignored desktop=WxH current=WxH reason=v1_no_recreate
event=virtual_display_teardown result=0|1 reason=<peer_restore|peer_closed|agent_exit|session_end|input_receiver_error>
    requested=<...> display_id=ID child_exit=<code> forced=<none|sigterm|sigkill> ms=N
event=virtual_display_child_exit expected=0 code=N display_id=ID reason=unexpected capture=physical_unchanged
event=virtual_display_lost result=1 display_id=ID code=N
event=display_state_before online=N id=... main=... pixels=... points=...   （每会话一次）
event=display_state_after  online=N ...                                      （每会话一次）
event=virtual_display_child_display_state_before/_after ...                  （子进程视角）
event=virtual_display_child_ready display_id=... physical=... ...             （子进程）
event=virtual_display_child_restore result=0|1 display_id=... ms=N [reason=]   （子进程）
event=virtual_display_child_mode_saved saved=WxH current=WxH                   （子进程）
event=virtual_display_child_mode_restored result=0|1 saved=WxH current=WxH reason=pre_session|teardown|setup_failed
event=virtual_display_child_mirror result=0|1 physical=ID virtual=ID configure=N complete=N
event=virtual_display_child_size_check result=1 expected=WxH bounds=AxB physical_mirrors=ID virtual_id=ID
event=virtual_display_child_stderr line=<sanitized>                            （父进程转发子进程 stderr）
event=virtual_display_physical_restore result=0|1 reason=<teardown|spawn_failure:*|child_lost> saved=WxH current=WxH
event=virtual_display_retry result=0 attempt=1|0 reason=<stage> [skipped=1] delay_ms=500
event=virtual_display_spawn result=1 stage=<launch|handshake|ready_timeout|physical_offline|physical_not_real>
```

## 5. Feature gate 与回滚

- 默认 **关闭**：只有 `RDP_AGENT_VIRTUAL_DISPLAY=1` 才启用；未设置/其他值完全走原物理采集路径
  （harness 的 gate-off 用例断言无子进程、无显示排列变化、采集仍为 fit 2214x1440）。
- 回滚：移除该环境变量并重启 Agent（`launchctl kickstart -k`）即可；无需改数据或二进制。
- 当前部署 wrapper `scripts/run-agent-stream.sh` 的 `exec env ...` 未包含该变量（保持关闭）。
  现场验收时需在 wrapper/launchd env 中显式加入 `RDP_AGENT_VIRTUAL_DISPLAY=1`（成对部署由维护者执行）。
- `RDP_AGENT_MATCH_DISPLAY_MODE` 代码默认开启（仅字面 `"0"` 关闭）；虚拟显示器启用时不再走 auto mode matching，无需手工设置。

## 6. 时序（一次 RDP 会话）

1. Agent 启动，物理采集循环立即开始（不受虚拟显示器影响，Worker 的激活帧 deadline 有帧可用）。
2. Worker peer 激活 → IPC type 9 到达 → 若首次：父进程 spawn 子进程。
3. 子进程创建虚拟显示器 + mirror（本机实测 ready 0.5–0.6 s）→ stdout 握手 → 父进程日志 ready。
4. 下一次 `DisplaySizeMonitor` 轮询（≤500 ms）发现 native 变为 2560x1440 → geometry `policy=exact` →
   采集请求/SCStream 配置变为 2560x1440（SCStream 走既有 `updateConfiguration` 路径）。
5. 会话结束：type 17 / socket EOF / Agent 退出 → 子进程收 stdin EOF → 解除 mirror（实测 ~0.35–0.4 s）
   → 退出，WindowServer 移除虚拟显示器 → 物理显示器回到原模式（实测 0.1–0.5 s 内恢复 native）。
6. 崩溃安全：Agent 被 SIGKILL / 子进程被 SIGKILL 时，子进程 stdin EOF 或 XPC 连接断开都会自动
   解除 mirror 并移除虚拟显示器（实测无残留）；子进程侧另有 SIGTERM/SIGINT/SIGHUP 处理。

## 7. 已知限制 / 风险（P0 范围）

- **多显示器**：v1 只支持单显示器开发环境；若物理显示器已经处于 mirror 链（`CGDisplayMirrorsDisplay != 0`），
  子进程拒绝启动（`event=virtual_display_spawn result=1 ... reason=physical_already_mirrored`，
  保持物理采集）。带外接屏的完整排列快照/恢复未实现。
- **DISP 中途 resize**：v1 不重建虚拟显示器，只记 `virtual_display_resize_ignored`；geometry 仍按新的
  desktop box 重算（fit 到 2560x1440 虚拟采集），鼠标映射保持一致。客户端当前不发 DISP，后续再实现重建。
- **系统版本**：依赖 CoreGraphics 私有 ObjC 类与 mirror framebuffer 行为，只在 macOS 27.x 验证；
  升级系统后必须重跑 `make test-virtual-display`。
- **合盖/无物理显示器**：笔记本合盖且无外接显示器时，macOS 会把内置屏从 WindowServer 移除、只剩
  遗留虚拟显示器；本修复后 Agent 会检测到 physical display 离线/虚拟并拒绝创建（不再级联），但此时
  RDP 画面本身也失去物理来源，需要用户开盖/接外屏恢复；若 WindowServer 已遗留 ghost 虚拟显示器，
  可能只能通过重启 WindowServer/重登清理解除。
- **观感**：虚拟显示器成为 main display，物理面板显示 letterbox 的 16:9 内容；会话期间用户本地看到的
  是缩放后的桌面，会话结束恢复原排列。
- **软重启差异**：子进程与被禁用的私有 API 不涉及 SIP/TCC 修改；子进程不请求任何 TCC 权限。

## 8. 验证（macOS 27.x，2026-11-08）

- `make agent-check`：通过（含新增 `VirtualDisplayTests`：gate/握手/状态机/恒等坐标）。
- `swift build -c release --package-path native/macos`：通过。
- `make test-virtual-display`（headless harness，4 用例，约 8 s）：
  - 主流程：ready `width=2560 height=1440`，`ms≈0.5–0.6s`；SCK `displays` 见 2560x1440；
    采集帧 `2560x1440`（policy exact）；type 17 teardown result=0；恢复 `online=1 native 约 2.9K`。
  - 部署版路径：`RDP_AGENT_CAPTURE_STREAM=1 RDP_AGENT_DELTA_FRAMES=1 TARGET_FPS=60` 下无
    `capture_stream_fallback`，delta 帧 2560x1440，teardown 正常。
  - 默认关闭：无子进程、采集 fit 2214x1440、显示排列不变。
  - SIGTERM/断开：显示恢复、无残留子进程。
- 采集正确性旁证（调试 helper）：mirror 期间 `SCScreenshotManager` 用**缓存的物理 filter** 采集
  2560x1440，与直接采集虚拟显示器的像素 mean abs diff 0.44（采样点），行亮度 profile 一致 → 无黑边。
- **fix round（2026-11-08 重连缺陷）已验证**（笔记本内置屏开盖、native 约 2.9K）：
  - `make agent-check` PASS；`swift build -c release` PASS；
  - `make test-virtual-display` / `python3 scripts/test-virtual-display-integration.py`：**6/6 OK**，
    连跑两轮均通过（每轮 ~40 s），每次结束后面板回 native 约 2.9K、无遗留 child/虚拟显示器；
    数字（两轮）：多会话重连 2560→1920→2560 ready_ms [1169,832,1251] / [1127,1383,1149]，
    spawn_failures=0，每次 teardown 后恢复 native；非 native 面板恢复（中途 1920x1200 → 2560x1440
    会话）ready=1，startup mode 恢复约 2.9K；SCStream+delta 部署路径 frames=2560x1440、无 fallback；
    snapshot 主流程 ready_ms≈1.06–1.33 s；SIGTERM 恢复、gate-off（无 child、fit 2214x1440）均通过。
  - 说明：ready 从 ~0.5 s 升到 ~0.8–1.7 s（pre-session 模式事务 + runloop pump）；spawn 期间物理采集
    持续出帧，Worker 激活帧 deadline 不受影响。
- **尚未验证**：真实 Windows App 现场（观感、鼠标指针物理位置 vs RDP 坐标的手感、60fps 流畅度、
  断线重连多次后的稳定性）——需维护者成对部署后由人工验收。

## 9. 2026-11-09 补记：输入映射 target 修复（真机验证）

- 已在 macOS 26.x（Apple Silicon，单显示器“看起来像 2560x1440”）上，用 macOS Windows App 与 Win11 `mstsc`
  确认虚拟显示器路径的鼠标偏移修复（候选构建版本 0.2.2）。
- 修复契约与实现见 [DESIGN-2026-11-07-resolution-adaptation.md](DESIGN-2026-11-07-resolution-adaptation.md) §12；
  根因/证据见 [DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md](DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md)。
- 现场旁证日志：`event=input_target source=virtual`；若出现 `event=input_target_fallback reason=bounds_mismatch`
  说明该系统的虚拟屏 bounds 与 capture 不一致，需回传该行进一步分析。
