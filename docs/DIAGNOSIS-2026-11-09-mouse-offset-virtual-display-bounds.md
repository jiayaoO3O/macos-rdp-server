# DIAGNOSIS-2026-11-09 鼠标错位：虚拟显示器路径的输入坐标空间错配

> 触发：维护者把 0.2.2 包安装到工作机（macOS 26.x，Apple Silicon，单台显示器，系统设置“看起来像 2560x1440”），
> 用 macOS Windows App（局域网）与 Win11 远程桌面两个客户端验证：文本/文件剪贴板正常、分辨率与帧率正常，
> 但鼠标错位——客户端光标在意图位置，被控 macOS 的实际落点在其**左上**，越往右下偏差越大（左上角基本对齐）。
>
> 关联：[DESIGN-2026-11-07-resolution-adaptation.md](DESIGN-2026-11-07-resolution-adaptation.md)（fit-with-bars/鼠标坐标契约）、
> [DESIGN-2026-11-08-virtual-display.md](DESIGN-2026-11-08-virtual-display.md)（虚拟 16:9 显示器）、
> [STATUS-2026-11-08.md](STATUS-2026-11-08.md)（当前状态）。
>
> 结论状态：**已修复并经真机验证（2026-11-09 下午）**。根因是服务端 Agent 的输入映射在虚拟显示器
> 激活时仍使用物理屏 bounds；修复已合入 `main`（commit `e13c9d3`）。带修复的候选构建（版本 0.2.2）
> 安装到 macOS 26.x 工作机（Apple Silicon，显示器“看起来像 2560x1440”），
> 用 macOS Windows App 与 Win11 远程桌面两个客户端实测确认鼠标恢复对齐。
> **注意**：工作机日志/`CGDisplayBounds` 数值没有取回（现场限制），所以“macOS 26.5.1 mirror 保留
> 物理屏 HiDPI points”这一步是由“左上对齐 + 误差向右下增长”的比例症状 + 27.2 对照实验推断的；
> 行为修复结果与推断一致。下次连接可用 §6 的日志/`event=input_target` 做一次旁证。

## 1. 现象与判定

| 观察 | 结论 |
| --- | --- |
| 视频 1:1、帧率正常、无黑边/拉伸 | 采集帧尺寸 == 协商桌面框（`policy=exact`）；排除 fit-with-bars 回退（那会带黑边） |
| 文本/文件剪贴板双向正常 | CLIPRDR 与 Agent IPC 正常，排除连接/认证/单连接租约类问题 |
| 两个**不同厂商实现**的客户端（Windows App / mstsc）同方向偏移 | 偏移发生在服务端注入链路（客户端只提供桌面坐标并自绘光标） |
| 左上角基本对齐、误差向右下线性增大 | 比例缩小映射（注入点 ≈ r·客户端坐标，r<1），不是常数偏移 |
| 初判“恒定偏移”，四角复测后修正为“左上对齐、右下更大” | 采用比例缩小结论（§3 的 H1 类） |

## 2. 映射链与不变量（FACT，file:line）

```
客户端 TS_INPUT (x,y)  ——桌面像素坐标（MS-RDPBCGR；客户端负责把自己的窗口/缩放坐标换算回来）
  → Worker mouse()/send_mouse_event：只 clamp 到 ctx->width/height，无任何缩放
       internal/worker/native.c:341-360（send_mouse_event）、2523-2533（mouse 回调）
  → Agent IPC type 3 kind=1 → InputController.applyMouse
       native/macos/Sources/rdp-agent/main.swift:2063-2067、2211-2310（applyMouse）
  → DisplayCoordinateMapper.desktopPoint：desktop → fit 布局 → capture 像素 → 显示器 points
       native/macos/Sources/MacAgentCore/DisplayLayout.swift:84-102（capturePoint）
       native/macos/Sources/MacAgentCore/DisplayCoordinateMapper.swift:28-37、54-66
       point = CGDisplayBounds(注入 display).origin + bounds.size * capturePixel / captureSize
  → CGEvent(mouseMoved/Dragged/button, at: point).post(.cghidEventTap)
```

**核心不变量**：`CGDisplayBounds(注入 display)` 所描述的坐标空间必须与**采集帧覆盖的空间**一致。
- 非虚拟显示器（普通物理采集/fit-with-bars）：采集帧就是该物理屏 framebuffer，bounds 用物理屏 → 正确
  （本机用真实 Agent + 假 Worker 实测，fit 路径逐点符合公式，见 §4）。
- 虚拟显示器激活：采集帧是**虚拟显示器**的 framebuffer（1x，尺寸==桌面框==capture），
  注入应使用虚拟显示器（mirror master）的 bounds；继续用启动物理屏的 bounds 只有在
  “物理屏 bounds 尺寸也等于 capture”时才是恒等（macOS 27.2 恰好如此，见 §4）。
- Worker 侧没有任何指针/光标 PDU（未开 MS-RDPEMSC），客户端看到的鼠标 100% 由客户端自绘，
  服务端唯一能造成偏移的地方就是上面的 `point` 计算。

## 3. 根因（比例症状 + 27.2 对照推断；修复结果已验证一致）

虚拟显示器镜像期间，Agent 的输入映射仍使用 `CGDisplayBounds(启动时物理 displayID)`（`main.swift:2213`），
而采集帧是虚拟屏 framebuffer。macOS 27.2 上 mirror 会把物理屏强制为虚拟屏的 1x 模式，于是
`physical pixels == physical points == capture`，映射退化为恒等，bug 被掩盖；macOS 26.5.1 上
（推断）物理屏在 mirror 期间保留了原生 HiDPI 的 **points** 尺寸（例如 2560x1440），而 mode 像素/capture
是会话桌面框的像素尺寸（例如 3840x2160），于是：

```
注入点 = physical_points / capture_pixels × 客户端坐标     # r = 2560/3840 ≈ 0.667
```

| 会话分辨率（capture/desktop） | 假定物理 bounds(points) | 比例 r | 客户端在中心 (1920,1080) 时实际落点 | 客户端在右下角 (3840,2160) 时实际落点 |
| --- | --- | --- | --- | --- |
| 3840x2160（4K，用户所述“应该是 4K”） | 2560x1440 | 0.667 | (1280,720)，偏左上 (640,360) | (2560,1440)，偏左上 (1280,720) |
| 5120x2880（5K 全屏） | 2560x1440 | 0.500 | (960,540) | (2560,1440)，只能到屏幕一半 |
| 2560x1440（与“看起来像”一致） | 2560x1440 | 1.000 | 无偏差 | 无偏差 |

这解释了全部症状：左上角（原点）对齐、误差随距离线性增长且恒向原点（左上）；视频/分辨率/剪贴板
完全不经过这条路径，所以都正常；两个客户端同错。

**为什么不是客户端**：客户端只把本地指针换算成 RDP 桌面坐标（协议语义），同一坐标空间在
Windows App 与 mstsc 上都由各自实现负责；两者同方向、同量级的比例缩小，更符合服务端注入坐标被统一缩小。
Windows App 的书签里确有 `smart sizing:i:1`（本机导出日志可见），但那是客户端把会话画面适配窗口的设置，
只有在客户端自身坐标换算有 bug 时才会造成偏移；现场可用 §6 的 harness 一步区分（虚拟路径 identity ⇒ 客户端侧）。

## 4. 本机实测（FACT，macOS 27.2，外接 2x 屏 4096x2304px / 2048x1152pt）

1. **镜像期间显示 bounds**（`/tmp/dpy_probe`，真实 `rdp-agent virtual-display` 子进程）：
   DURING 2560x1440：虚拟屏 id=15 `main=1 pixels=0x0 points=2560x1440`；
   物理屏 id=3 `active=0 mirrors→15 mode pixels=2560x1440 points=2560x1440`（identity，HiDPI 被关闭）。
   2508x1220 同理；teardown 后 3/3 精确恢复 4096x2304/2048x1152、无残留。
2. **Agent 端到端映射**（真实 dist 版 Agent + 假 Worker，读真实指针位置；`/tmp/agent_input_harness.py`）：
   虚拟路径 2560x1440 与 2508x1220 的 7 个探测点（含四角/中心）**全部 请求(x,y) == 实测指针(x,y)**（Δ≤0.34pt 光标量化），
   28/28 stable；控制路径（`RDP_AGENT_VIRTUAL_DISPLAY=0`）与实现公式逐点一致（如 2508x1220 fit 2169x1220 黑边 clamp）。
3. **真实会话日志**（本机 app 日志）：`virtual_display_child_ready ... id=11 main=1 pixels=0x0 points=2560x1440
   id=1 main=0 pixels=2560x1440 points=2560x1440`；`display_size_changed native=2560x1440 desktop=2560x1440
   capture=2560x1440 policy=exact`；`peer_frame_layout ... offset=0,0 scaled=0`。
   → 27.2 上虚拟屏 bounds 与 capture 相等，输入恒等，**本机无法复现现场的比例偏移**。
4. **协议层排除**（源码 + FreeRDP 3.32.2）：Worker 只做 `x=min(x, ctx->width-1)`；FreeRDP server 从
   TS_POINTER_EVENT 原样回调，不引用 DesktopWidth/Height 缩放；Worker 不发送 pointer/cursor PDU；
   `test_21/21b/21c` 覆盖了桌面坐标原样转发与 fit-with-bars 映射。

## 5. 修复（已合入 main：commit `e13c9d3`；真机验证通过）

设计：**虚拟屏 active 且其 bounds 尺寸（四舍五入）等于当前 capture 尺寸时，输入改用虚拟屏 displayID + bounds；
否则回退启动物理屏 bounds（旧行为，fit 路径零变化）**。这样：
- 27.2（bounds==capture）：选虚拟屏，坐标与旧实现完全相同（无回归）；
- 26.5.1（physical points != capture）：选虚拟屏 1x bounds，恢复恒等映射；
- mirror 切换 ~1s 内 capture 还是 fit、或虚拟屏已死/被拆：自动回退物理屏，不会注入到失效 display。

改动（4 files, +340/−3；commit `e13c9d3`，修复时先在独立 worktree 验证）：

| 文件 | 改动 |
| --- | --- |
| `native/macos/Sources/MacAgentCore/DisplayCoordinateMapper.swift` | 新增纯逻辑 `InputDisplaySource` / `InputDisplayTarget` / `InputDisplayTargetResolver.resolve(...)`（可单测，无需新增文件） |
| `native/macos/Sources/rdp-agent/VirtualDisplayController.swift` | 独立 NSLock 缓存的 `activeDisplayID`（避免 `queue.sync` 被 stopChild 阻塞）；handshake 成功置位，teardown/EOF/child crash/超时全部清空 |
| `native/macos/Sources/rdp-agent/main.swift` | 生产输入分支每事件解析 target（含 `CGDisplayIsActive`/bounds 采样与 stale 回退）；新增限频诊断 `event=input_target`、`event=input_target_fallback`；`remote_input_dropped` 追加 `input_source=` |
| `native/macos/Tests/MacAgentCoreTests/VirtualDisplayTests.swift` | resolver 用例：virtual 命中/无 virtual/退化 bounds/capture 不匹配回退/HiDPI 比例语义；旧 fit 期望由 `PermissionSnapshotTests` 回归 |

### 验证（合入前 worktree + 合入后 main）

- `make agent-check` **exit 0**（主树与 worktree 均绿）；RED 证据：把 resolver 临时改回“永不选 virtual”后
  `VirtualDisplayTests.swift:39: Precondition failed`（exit 2），还原后绿。
- `swift build -c release --package-path native/macos` → `Build complete!`
- `make check` + `go test -race -count=1 ./...` → 全绿。
- 合入后组合构建（`main` = SDK/pipe2 合并 + 本修复）：`dist/RDPServer-0.2.2.dmg`，12,481,414 B，
  `nm -u` 无 `_pipe2`、
  嵌套 agent 含 `event=input_target`、`codesign --verify --deep --strict` 通过。

### 真机验收（2026-11-09，真机执行并确认）

- 维护者把带修复的候选构建（版本 0.2.2）安装到 macOS 26.x 工作机
  （Apple Silicon，单显示器“看起来像 2560x1440”）。
- 局域网 macOS Windows App 与 Win11 `mstsc` 两个客户端：视频/分辨率/帧率/剪贴板正常，**鼠标恢复对齐（问题修复）**。
- 工作机日志/`CGDisplayBounds` 数值未取回（现场限制）；根因数值证据由本机 27.2 对照 + 症状比例推断，
  修复结果与推断一致。组合包未在 macOS 26 真机复测。

## 6. 事后旁证（可选；用于确认/回归，macOS 26.5.1 工作机）

日志目录（DMG App 安装）：`~/Library/Application Support/RDPServer/logs/`；旧 LaunchAgent 部署则是
`.runtime/agent-launchd.log` + `.runtime/worker-live.log`。

```sh
# [1] 最关键：mirror 瞬间每个 display 的 pixels/points
grep -aE "virtual_display_(spawn|ready|skipped|child_ready|teardown|child_restore)" \
  ~/Library/Application\ Support/RDPServer/logs/agent.log | tail -n 30
# [2] 会话几何：native/desktop/capture/policy
grep -aE "display_inventory|display_size_changed" \
  ~/Library/Application\ Support/RDPServer/logs/agent.log | tail -n 20
# [3] 协商桌面框与合成布局（应 offset=0,0 scaled=0）
grep -aE "peer_size_negotiated|peer_frame_layout" \
  ~/Library/Application\ Support/RDPServer/logs/worker.log | tail -n 15
```

判读（[1] 中物理屏那一项，`id=<物理屏> main=0 pixels=… points=…`）：
- `points=3840x2160`（== pixels/capture）→ 虚拟路径 identity，本诊断假设不成立 → 偏移在客户端侧
  （Windows App 的 smart sizing/Retina、mstsc 显示缩放），需要看 §7 的 harness 结果再定。
- `pixels=3840x2160 points=2560x1440`（points < capture）→ **命中本文根因**，§5 修复生效。
- 无 `virtual_display_ready` / `policy=fit` / `peer_frame_layout scaled=1` → 虚拟显示器未生效，
  先查 `virtual_display_skipped reason=` 与权限/单显示器条件。

定量 harness（可选，约 1 分钟，自恢复）：仓库外诊断脚本/压缩包（如 `/tmp/rdp-mouse-diag-26.tar.gz`）。
解包后 `./run.sh --quick`（或 `--logs-only` 只取日志不动屏幕）；用真实安装的 RDPAgent + 自建假 Worker
直接测量 `RDP 坐标 → macOS 实际指针`，输出 identity / slope=bounds/capture / 常数 offset / 虚拟未生效 四类判读。
前提：本机 GUI「终端」运行（禁 ssh/sudo）；Screen Recording 与 Accessibility 已授予 RDPAgent.app 身份；
:3389 无 ESTABLISHED；仅一个在线显示器。

**临时缓解（不改代码，可选）**：把客户端会话分辨率设为与显示器“看起来像”一致（2560x1440）。
若本文假设成立，r=1 应对齐；若仍偏，说明 26.5.1 的 bounds 行为不同（或客户端侧），需以 §6 数据为准。

## 7. 部署与回滚（发版流程；候选构建已在工作机验证）

1. **源码**：commit `e13c9d3` 已在 `main`（与 `723b8b2` 的 SDK/pipe2 构建修复合并）。
2. **安装**：工作机已安装带修复的候选构建（版本 0.2.2，真机验证）；如需组合包，用当前 `main` 重新 `make app-dmg`，
   或使用本机构建的 `dist/RDPServer-0.2.2.dmg`（未真机复测）。
3. **重新授权 TCC**：新 ad-hoc 签名后，在系统设置→隐私与安全中移除旧 `RDPAgent.app`（DMG 场景是
   RDPServer.app 内嵌套 agent）的屏幕录制/辅助功能记录并重新添加，然后重启 Agent/App；否则无帧或注入无效。
4. **成对部署/回滚**：Worker/Agent 同窗口替换；LaunchAgent 先停 worker → `rm -f .runtime/agent-compat.sock` →
   起新 worker → `launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent`。DMG：退出旧 App → 装新包；
   回滚时旧包成对恢复并再次重授权。
5. **回归旁证**：新包 agent.log 应出现 `event=input_target source=virtual display_id=… bounds=… capture=…`；
   若反复 `event=input_target_fallback reason=bounds_mismatch/display_unavailable`，回传该行。

## 8. 证据与产物清单

| 产物 | 位置 | 说明 |
| --- | --- | --- |
| 本诊断 | `docs/DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md` | 本文件（结论已更新为真机验证通过） |
| 修复提交 | `e13c9d3`（main） | 4 个 Swift 文件，+340/−3 |
| 修复工作树 | 独立 worktree（未入库） | 修复时自测/DMG 构建；main 已含等价代码 |
| 真机验证的候选构建 | 版本 0.2.2 | 已安装于 macOS 26.x 工作机；真机确认鼠标修复 |
| 组合构建（本机） | `dist/RDPServer-0.2.2.dmg` | 未在 macOS 26 真机复测；校验和以当次构建为准 |
| 现场诊断 kit | 仓库外诊断脚本/压缩包 | harness + 探针 + README + 3 条 grep（供后续旁证/回归） |
| 本机 harness 结果 | `/tmp/input_harness_results.json`、`/tmp/agent_input_harness.py`、`/tmp/dpy_probe` | macOS 27.2 identity/公式一致证据 |

> 后续（可选）：把工作机 agent.log 的 `event=input_target` / `virtual_display_child_ready` 保留为数值旁证；
> 在组合包上补跑 `test-app-bundle` 与 `test-virtual-display`。
