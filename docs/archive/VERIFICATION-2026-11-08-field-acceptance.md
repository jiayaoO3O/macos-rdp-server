# 2026-11-08 真机验收记录（Windows 11 mstsc，局域网 3389；历史快照）

本文件记录 2026-11-08 当天在**真实 Windows 11 客户端（mstsc.exe，局域网，全屏模式）**上
对局域网 3389 会话的逐项验收结果。与 loopback 测试不同，这里的结论全部来自维护者实际操作 +
worker/agent 日志证据；未验证项明确标注。文中 IP/PID/哈希均属当时快照，不代表当前环境。

## 环境

- 服务端：`bin/rdp-worker`（Go + FreeRDP 3.32.2）+ `bin/RDPAgent.app`（LaunchAgent
  `com.rdp-server.agent`），监听 `<LAN-IP>:3389`，macOS 面板原生约 2.9K。
- 客户端：Windows 11 主机上的 `mstsc.exe`，全屏。
- 维护者明确授权直接重启/重新部署，无需逐次询问。

## 验收结果

| # | 项目 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | 鼠标对齐（黑边/边缘漂移） | **通过** | 真机确认；worker `send_mouse_event` 桌面坐标原样转发修复（`07942eb`），`test_21/21b` |
| 2 | 鼠标滚轮方向 | **通过** | 真机确认；`RDPWheel.macOSWheel1` 按 Windows 方向（`2641480`） |
| 3 | Windows → macOS 文件粘贴 | **通过** | 真机确认双向成功；关键修复见下 |
| 4 | macOS → Windows 文件粘贴 | **通过** | 真机确认双向成功；关键修复见下 |
| 5 | 自动分辨率（黑边消除） | **通过（虚拟 16:9 显示器方案）** | 2560x1440 采集=桌面=1:1，无黑边；重连序列 2560→1080→2560 全部通过，见下 |
| 6 | 窗口缩放动态分辨率（DISP） | **未验证/客户端限制** | 真实 mstsc 会话仍未发送 monitor layout；服务端 DISP 就绪，见 `docs/DIAGNOSIS-2026-11-08-disp-window-resize.md` |

## 文件剪贴板：真实客户端根因与修复（本次最大突破）

### Windows → macOS

**根因（字段证据 10:32 会话）**：mstsc 用**动态 formatId + 长名字**通告注册格式：

```
event=clipboard_client_format index=1 id=49269 name=FileContents
event=clipboard_client_format index=2 id=49314 name=FileGroupDescriptorW
event=clipboard_client_format index=0 id=49319 name=Preferred DropEffect
event=clipboard_client_format index=3 id=49337 name=ZoneIdentifier
```

旧实现按名字选中 FileGroupDescriptorW，却仍用固定 id `0xC003` 发
`CB_FORMAT_DATA_REQUEST`，客户端不认识该 id → `CB_RESPONSE_FAIL` →
`clipboard_file_rejected reason=client_failed`。FreeRDP probe 用固定 id，所以 loopback 测不出来。

**修复（`433f327`）**：`rdp_clipboard_select_format` 返回语义 kind + **客户端通告的
formatId**；数据请求用该 id；pending 状态按语义派发；服务端文件通告补上长名字
`FileGroupDescriptorW` / `FileContents`（Windows 客户端按名字映射）。

### macOS → Windows

**根因 1（`433f327` 附带）**：服务端文件通告没有 formatName，客户端无法映射格式；
补名字后客户端开始请求 descriptor（`clipboard_local_descriptor_response`）。

**根因 2（字段证据 11:48 会话）**：mstsc 请求 `FILECONTENTS_RANGE` 时**不按 EOF 截断**，
最后一块仍请求满 262144 字节；旧实现 `offset+len > size` 直接回 `bad_range`，Windows
粘贴报“未指定的错误”。Windows 服务端实际返回**短块**。

**修复（`4fc6d05`）**：新增 `rdp_clipboard_clamp_range`：`offset==size` 返回 0 字节
EOF 响应；`offset+requested > size` 截断为 `size-offset` 返回短块；仅 `offset>size`、
`requested==0`、超过 4 MiB 上限才拒绝。probe mode 12 增加
`RDP_PROBE_OVERLONG_RANGE=1` 复现 mstsc 行为，`test_24` 增加非整倍数/整倍数两个子用例
（fail-before：旧 worker `reason=bad_range` + probe rc 22）。

### TCC 教训（`97aba2b`）

期间为受保护目录实现的 Agent 暂存（staging）反而让 Agent 自己去读 `~/Downloads` 文件，
被 macOS TCC 弹窗阻塞在 `open()`（sample 栈可见），导致“复制没反应”且无日志。由于
worker 由启动它的 shell 拉起、本来就能读这些目录，staging 已改为**默认关闭**
（`RDP_AGENT_CLIPBOARD_STAGING=1` 才启用）；默认由 worker 直接读原路径。受保护目录
（桌面/文稿/容器）需要给 `RDPAgent.app` 完全磁盘访问权限后才适合用 staging。

### 复测命令与日志锚点

```
# 期望（双向成功时）
event=clipboard_client_data_request id=<客户端通告的 FileGroupDescriptorW id> kind=files
event=clipboard_client_format ... name=FileGroupDescriptorW
event=clipboard_file_request direction=local_to_remote ... length=<clamped> requested=262144
event=clipboard_file_complete direction=local_to_remote files=1 bytes=<n> result=0
event=clipboard_file_offer direction=remote_to_local count=1 bytes=<n>
```

## 自动分辨率（黑边）：尝试与结论

先选择“自动改 Mac 显示器分辨率”。实测可用模式（`CGDisplayCopyAllDisplayModes`）：
`1920x1200 / 2048x1280 / 2048x1332 / 2560x1600 / 2560x1664 / 2940x1836 / 约 2.9K /
3420x2136 / 3420x2224` —— **没有 16:9 模式**，面板原生 约 2.9K（1.538），典型客户端
2560x1440（1.778）无法精确匹配。

实现（`a0ef123`）在 IPC type 9 时按最小宽高比差切换显示模式（2560x1440 → 2940x1836，
黑边 173px → ~127px），并在 type 17/断线/退出时恢复原模式。

**真机结果：失败并已禁用。** 真机反馈“屏幕上下两条边一直在闪烁”：切到 scaled 模式后
macOS 在物理面板上 letterbox，且 capture 重配过程出现 `display_size_changed` 抖动
（日志可见 native 在 2560x1664/3420x2224/约 2.9K 间跳变），观感不可接受。

当前状态：
- 代码默认 **关闭**（`RDP_AGENT_MATCH_DISPLAY_MODE=1` 才启用），launchd 环境亦为 0；
- 显示模式保持原生 约 2.9K，左右黑边与之前相同；
- 下一步选择“创建自定义 16:9 分辨率”（私有 CoreGraphics API），进行中，见下文“未完成”。

## 虚拟 16:9 显示器：最终方案与验收（2026-11-08 晚）

自动切换显示模式的方案因闪烁被否决后，改为**创建 16:9 虚拟显示器 + 镜像物理显示器**，
由 ScreenCaptureKit 直接按客户端桌面框采集（详见
[DESIGN-2026-11-08-virtual-display](../DESIGN-2026-11-08-virtual-display.md)）。

现场验收（真实 Windows 11 mstsc，笔记本盖子打开、内建屏约 2.9K）：

1. 2560x1440 连接 → `virtual_display_ready ms≈880`，Worker
   `peer_frame_layout source=2560x1440 desktop=2560x1440 content=2560x1440
   offset=0,0 scaled=0` → **满屏无黑边、无变形**；
2. 断开 → `virtual_display_teardown result=0 reason=peer_restore` +
   `virtual_display_physical_restore saved=约 2.9K current=约 2.9K`，
   面板回到原生；
3. 1920x1080 连接 → 同样满屏；断开后恢复原生；
4. 再次 2560x1440 连接 → 仍然满屏（此前失败的序列）；
5. 真机结论：**“全部正常”**；鼠标对齐、文件复制双向也复测正常。

期间修复的四个叠加根因（详见 commit `241d444` 与设计文档 §9）：

1. WindowServer 按虚拟显示器身份（vendor/product/serial）持久化上次模式 →
   固定身份被 1920x1080 会话污染；改为每次 spawn 使用新的随机 product+serial；
2. Swift 子进程未驱动主 RunLoop，`CGVirtualDisplay.applySettings` 的模式应用
   block 不执行；改为所有等待循环 `CFRunLoopRunInMode`；
3. 短生命周期进程里裸 `CGDisplaySetDisplayMode` 随进程退出回滚；改为
   display-configuration transaction（`CGBeginDisplayConfiguration` +
   `CGConfigureDisplayWithDisplayMode` + `CGCompleteDisplayConfiguration`）；
4. 上一会话的 spawn 超时可能杀掉下一会话的子进程；引入 spawn generation token。

另外新增的保护（来自“合盖导致无物理显示器”的事故）：

- 无可用镜像目标（active built-in 或 active 非虚拟外接显示器）时
  `event=virtual_display_skipped reason=no_physical_display`，保持 fit-with-bars，
  避免虚拟显示器镜像到遗留虚拟显示器形成链条；
- 启动 `event=display_inventory` + `main_display_virtual` 告警，便于发现残留；
- 子进程 stderr 转发、失败时强制恢复启动模式并重试一次。

已知限制：多显示器排列的快照/恢复仍为 v1 简化（单物理显示器假设）；DISP 会话中
resize 不重建虚拟显示器（客户端 mstsc 目前不发 monitor layout）；目标硬件
**无头 Mac mini 4 + 外接 4K 16:9 显示器** 的路径已由保护逻辑接受，但仍需真机验证
（该硬件面板本身是 16:9，黑边问题预期天然不存在，虚拟显示器主要用于精确尺寸采集）。

## 未完成 / 下一步

1. **自定义 16:9 显示模式**（已选）：目标是不改内容、不拉伸，让 ScreenCaptureKit
   直接按 16:9（如 2560x1440）采集，RDP 客户端满屏无黑边。技术路线：CoreDisplay 私有
   `CGDisplayModeCreate`（dlsym 可用；字典 key 未知，需运行时恢复）+ 切换后 capture
   重配去抖；失败则退回虚拟显示器方案。验收前必须保证可恢复原模式。
2. **DISP 窗口缩放**：真实 mstsc 是否发送 monitor layout 仍无证据；服务端已就绪，
   需要客户端侧日志（Windows 上 `mstsc` 无公开 DISP 日志，可考虑 `RDP_TRANSPORT_DUMP`
   在隔离端口抓客户端请求）。未验证。
3. **TCC 持久性**：ad-hoc 签名重打包会改变 cdhash，受保护目录权限可能再次弹窗；
   后续可考虑稳定签名（自签证书）以持久化 TCC 授权。未验证。

## 部署记录（2026-11-08）

- Worker：`bin/rdp-worker` sha256 `（校验和略）`（HEAD `4fc6d05` 构建，含 cliprdr 动态 id +
  短块 clamp + IPC 17），部署于 12:00 前后；supervisor/child 由 `nohup` 启动。
- Agent：`bin/RDPAgent.app/Contents/MacOS/rdp-agent` sha256 `（校验和略）`（含 staging 默认关闭、
  clipboard_local_update 诊断、display mode 默认关闭），12:31 重新部署。
- 回滚：私有回滚快照（如 `.runtime/rollback-pre-<feature>-<date>/`）；Worker+Agent 必须成对回滚。
