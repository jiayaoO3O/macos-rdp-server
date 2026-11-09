# 审计复核答辩报告（答复 / A）

日期：2026-11-01。逐项回应
[`audit-review-questions-2026-11-01.md`](audit-review-questions-2026-11-01.md) 中的两项 P2。
问题报告作为历史记录保留，不覆盖原始复核结论。

## 1. 发送 deadline 测试现在验证服务端关闭

复核报告指出旧 mode 3 在睡眠后无条件输出成功标记，并且测试会匹配前序连接留下
的 watchdog 日志。现已调整：

- 客户端停止接收 7 秒后恢复 FreeRDP 事件读取，只有观察到 transport failure
  (`FREERDP_ERROR_CONNECT_TRANSPORT_FAILED`) 才输出 `server_close_observed` 并成功退出。
- Python 测试重启 worker、清空日志，隔离本次连接；检查耗时在 5–12 秒内、服务端
  deadline 日志存在，并在关闭后用新连接验证单连接租约已释放。
- 创建临时副本，将唯一发送 deadline 改成 `UINT64_MAX` 后重跑 mode 3 与 RefreshRect
  用例。两项均失败：mode 3 没有服务端关闭标记；刷新用例未观察到 transport close。
  故障注入副本位于批准的临时目录并已清理，没有改动工作区源码。

## 2. RefreshRect 与普通发帧共用有界发送入口

- 新增 `draw_pattern_with_deadline()`，负责在 `draw_pattern()` 前设置 5 秒 deadline，
  并在返回后清除（若 watchdog 未取消该 peer）。
- 普通事件循环发帧和 `RefreshRect` 回调均改走此入口。listener watchdog 在两种路径
  中都能通过 peer 的 duplicate socket 中止底层发送；RefreshRect 回调即使在
  `CheckFileDescriptor()` 内执行，也不依赖卡住的 peer 线程检查截止时间。
- 新增 mode 4：FreeRDP 测试客户端通过 `RefreshRect` API 请求整屏刷新，然后停止读取
  7 秒。`test_05d_refresh_frame_write_expires` 检查请求已发送、客户端确实观察到服务端
  transport 关闭、关闭时间在 5–12 秒内、隔离后的服务端日志包含超时事件，且租约
  释放后可重新连接。

## 最新验证

```sh
make check
make test-protocol
```

- `make check` 通过（Go race tests、go vet）。
- `make test-protocol`：10/10 通过，46.467 秒。包含普通发帧背压与 RefreshRect
  刷新背压两条超时路径。
- 截止时间故障注入：在临时副本关闭 5 秒 deadline 后，普通发帧与 RefreshRect 两个
  回归测试都按预期失败；复核报告指出的假阳性已被覆盖。

验收边界：测试基于 macOS arm64、FreeRDP 3.32.2 与当前 bitmap 探针；并非
Windows App / mstsc、LaunchDaemon 或其他图形通道验收。超时依赖系统 `shutdown()`
唤醒 socket I/O，当前验证覆盖本机实现。
