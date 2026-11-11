# 最终验收记录：菜单栏 App/DMG、键盘与剪贴板修复 — 2026-11-08

> 本文件是 2026-11-08 晚版包的**历史验收证据**，不是当前修复包的完整验收记录。2026-11-09 11:03 构建的 WinPR pipe2 修复包及 macOS 26.5.1 用户验证见 [STATUS-2026-11-08.md](STATUS-2026-11-08.md) §1.2 与 [VERIFICATION-2026-11-09-macos26-sdk-build.md](VERIFICATION-2026-11-09-macos26-sdk-build.md)；当前权威状态见 [STATUS-2026-11-08.md](STATUS-2026-11-08.md)。本文件中 `macOS 26 启动 SIGSEGV 未解决` 和 09:49 DMG 为当前包等说法均已被后续记录取代。

## 1. 环境

| 项 | 值 |
| --- | --- |
| 服务端 | macOS 27.x（开发机，Apple Silicon，面板约 2.9K） |
| 客户端 | Windows 11 主机上的 `mstsc.exe`（全屏），全新连接 |
| 网络 | 私有局域网（`address:"auto"` + `allow_lan:true`） |
| 部署形态 | 菜单栏 `RDPServer.app`（helpers 来自 `dist/RDPServer.app/Contents/Helpers`） |
| 诊断开关 | 验收期间开着 `RDP_AGENT_INPUT_TRACE=1`、`RDP_AGENT_EVENT_TAP=1`（仅键码+flags，不记文本）；验收后已恢复默认关闭 |

## 2. 真机验收项与结果（真机执行并确认）

| 验收项 | 结果 | 备注 |
| --- | --- | --- |
| 默认打字（英文/中文输入法） | ✅ | 不再吞字，普通字母不再触发系统面板 |
| 按 `Win+C` 后再连续输入 `e` | ✅ | 修复前必现「表情与符号」；修复后正常 |
| F 键/方向键之后再打字 | ✅ | Fn 位不再粘到后续按键 |
| 中文输入法切换（Ctrl+Space/CapsLock） | ✅ | control/shift 等 flags 正常 |
| Windows→macOS 文本复制粘贴 | ✅ | 一直正常，回归通过 |
| **macOS→Windows 文本复制粘贴（连续两段文本）** | ✅ | 修复前第二段失败；修复后均成功 |
| 双向文件复制粘贴 | ✅ | Windows→macOS、macOS→Windows 均成功 |
| Win+V 粘贴、Win+C 复制 | ✅ | Command 组合正常，无残留修饰键 |
| 画面（2560x1440 无黑边/无拉伸/重连） | ✅ | 虚拟 16:9 显示器方案，沿用既有验收 |
| 菜单栏 App / DMG 安装与运行 | ✅ | 用打包 App 连接测试 |
| **鼠标双击/多击**（标题栏缩放 / 打开文件 / 选词 / 三击选行） | ✅ 真机验收通过 | 注入事件携带 clickState 1/2/3；`MouseClickStateTests` 全绿 |
| 手动「释放卡住按键」移除（2026-11-09） | ✅ | 根因修复后按需求移除；自动释放路径保留；产物无 `release_stuck_keys`，self-test 28 项 |
| **最低系统版本（目标 macOS 26）** | ✅ 审计通过 | 包内全部 11 个 Mach-O `vtool -show-build` 均为 `minos 14.0`；`Info.plist LSMinimumSystemVersion=14.0`；修复前 rdpctl/worker 为 27.2、FreeRDP/OpenSSL 为 27.0，导致 macOS 26 保存凭据失败 |
| **OpenSSL legacy provider / MD4（macOS 26）** | ✅ 修复（0.2.1） | WinPR `WITH_INTERNAL_MD4/RC4`；`OPENSSL_MODULES=/tmp/nonexistent` 下 `rdpctl hash-stdin` 与 protocol **35 例（含 NLA）** 全绿 |
| **错误信息可复制** | ✅ 可用 | 错误横幅/凭据错误有「复制」按钮 + 文本可选中；字段/端口错误可选中（真实点击未自动化） |
| **版本号** | ✅ 0.2.2 | `RDPServer --version`、Info.plist、DMG 文件名同步 |
| **应用图标 / 菜单栏图标** | ✅ | 当时包内为 📟 图标；现 `AppIcon.icns` 为白色线稿寻呼机素材合成的深色图标（见 STATUS §1），菜单栏状态图标当时仍为 📟（2026-11-10 起改为同一造型的矢量模板图，见 STATUS §1） |
| **崩溃现场诊断（`RDP_WORKER_BACKTRACE=1`）** | ✅ 本地验证 | 对隔离 worker `kill -SEGV` 后输出 `event=worker_crash signal=11 frames=7` + `backtrace_symbols_fd`（含 libwinpr 符号） |
| **macOS 26 启动 SIGSEGV（本记录当时状态）** | ⚠️ 2026-11-08 未解决；2026-11-09 已解决 | 后续取回的 9 份 macOS 26.5.1 `.ips` 指向 WinPR `winpr_event_init` 调用弱导入 `_pipe2` 空槽；pipe()+fcntl 修复包见 STATUS §1.2，已确认成功 |

> 结论：真机确认“所有问题得到修复”。键盘根因与修复证据见 [DIAGNOSIS-2026-11-08-keyboard-swallowed-input.md](DIAGNOSIS-2026-11-08-keyboard-swallowed-input.md) §9。

## 3. 自动化测试基线（本轮最终代码）

| 命令 | 结果 |
| --- | --- |
| `make agent-check` | ✅ 全绿（含新增断言：Fn/NumericPad 永不进入显式 flags） |
| `go test -race ./...` / `go vet ./...` / `make check` | ✅ 全绿 |
| `scripts/test-protocol.py`（隔离 `/tmp` 构建，不覆盖 `bin/`） | ✅ **35 例 OK（1 skip = AVC420）**，约 94 s |
| 同上，但 `OPENSSL_MODULES=/tmp/nonexistent`（模拟没装 Homebrew OpenSSL 的 macOS 26） | ✅ 35 例 OK（1 skip），证明内置 MD4/RC4 足够完成 NLA |
| `scripts/test-agent-ipc-wire.py` | ✅ 5 例 |
| `scripts/test-agent-launchd.py` | ✅ 4 例 |
| `test-app-core.py --with-service` | ✅ 全绿 |
| `make app-dmg` | ✅ 09:49 旧版 DMG 生成；11:03 另行重建 pipe2 修复包（已确认 macOS 26.5.1 启动成功，详见 STATUS §1.2） |
| `make test-app-bundle` | ✅ **17 passed / 0 failed / 0 warning** |
| 打包 App `--self-test` | ✅ 28/28 |

## 4. 打包制品（本轮最终）

| 制品 | 说明 |
| --- | --- |
| `dist/RDPServer-0.2.2.dmg` | 2026-11-09 09:49 构建；版本 0.2.2；全部 Mach-O minos 14.0；**不含后续 pipe2 修复** |
| **后续修复包** | 11:03 构建；完整核验/确认见 STATUS §1.2 与 VERIFICATION-2026-11-09-macos26-sdk-build.md |
| `dist/.../Helpers/{rdp-worker,rdpctl}`、嵌套 `RDPAgent.app` | 随 DMG 一起构建；校验和以当次构建为准 |

- DMG 从 clean 的最终提交树重新构建；产物内可检索到 `clipboard_local_advertised`、`input_win_command_released`、`input_event_tap`、`input_multi_click`，`release_stuck_keys` 字符串 0 命中，全部 Mach-O minos 14.0。
- bundle 校验见 `make test-app-bundle`（§3）。

## 5. 未覆盖/待确认

- 无头/合盖 Mac mini + 外接 4K 16:9 真机路径仍未验证（2026-11-09 已验证的是 Apple Silicon 工作机 + 单台“看起来像 2560x1440”显示器）；
- DISP 会话中实时改分辨率仍受客户端限制（见 STATUS §2）；
- 其它机器上的 DMG 首次打开可能需右键→打开/重新授权（ad-hoc 签名、未公证）。

## 6. 2026-11-09 补记：虚拟显示器鼠标错位修复真机验收

- 背景：macOS 26.x 工作机（Apple Silicon，单显示器“看起来像 2560x1440”）上，虚拟显示器激活时鼠标“左上角对齐、
  越往右下偏越多”；局域网 macOS Windows App 与 Win11 `mstsc` 两个客户端一致；视频/帧率/剪贴板正常。
- 根因与修复：Agent 输入映射仍用物理屏 `CGDisplayBounds` 换算虚拟屏采集像素；修复 commit `e13c9d3`
  （虚拟屏 active 且 bounds==capture 时用虚拟屏 bounds 注入，否则回退物理屏）。详见
  [DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md](DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md)。
- 真机验证：带修复的候选构建（版本 0.2.2）已在 macOS 26.x 工作机安装，用
  Windows App（局域网）与 Win11 `mstsc` 实测确认鼠标恢复对齐；**未采集该机日志/bounds 数值**。
- 自动化：`make agent-check` 全绿，含 `VirtualDisplayTests` 新增的 `InputDisplayTargetResolver` 断言
  （RED 证据：旧语义在 `VirtualDisplayTests.swift:39` 失败）。
- 组合包：`main` 与 SDK/pipe2 构建修复合并后重建 `dist/RDPServer-0.2.2.dmg`；本机构建/codesign/`nm`
  检查通过，**未在 macOS 26 真机复测**；校验和以当次构建为准。

