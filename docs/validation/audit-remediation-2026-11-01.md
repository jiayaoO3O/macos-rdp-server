# 独立审计问题修复记录

日期：2026-11-01。对应 `independent-audit-2026-11-01.md` 的三项发现。

## 修复

### P1：TLS/NLA 阶段停滞超时

- 每个 accept 的 peer 现在持有原 socket 的 `dup()` 描述符，设为 close-on-exec。
- listener 线程每 100 ms 检查活动 peer 的 deadline；到期后在 duplicate 上调用
  `shutdown(SHUT_RDWR)`，中断 FreeRDP 已接管的 socket。peer 线程退出并执行原有清理；
  deadline 仍会在 peer 槽释放前受到锁保护。
- 15 秒握手 deadline 覆盖 FreeRDP 内部 TLS/NLA 等待，不再依赖卡在
  `CheckFileDescriptor()` 的 peer 线程自己检查时间。
- TDD 回归：新增 `test_05b_tls_handshake_stall_expires`，发送审计报告中的 X.224
  协商请求并收到 HYBRID 响应，但不发送 TLS ClientHello。实现前测试在 18 秒处超时
  失败；实现后服务端约 15 秒关闭连接，测试通过。

### P2：发送 deadline 的取消路径

- 5 秒 deadline 由独立 listener watchdog 执行；即使 peer 线程同步阻塞于帧发送，
  watchdog 也能通过 duplicate 对底层 socket 执行 shutdown。
- 新增 `rdp-probe -mode 3`：收到初始帧并发送键鼠后停止读取 7 秒，模拟客户端接收
  背压。`test_05c_blocked_frame_write_expires` 确认服务端记录 `event=peer_deadline_expired`
  且客户端发现连接被关闭。该测试验证本机当前 bitmap 路径，不代表所有 FreeRDP
  虚拟通道或图形编码路径均已验证。
- 更新 `native/freerdp/README.md`，描述 duplicate descriptor 与实际取消机制。

### P2：认证拒绝路径的首帧断言

- 客户端探针包装 FreeRDP 的 `BitmapUpdate` 回调，记录收到的非空 bitmap update，
  并继续调用 GDI 原回调。
- 成功认证用例要求出现 `bitmap_update_seen`；错误密码、未知用户、错误域、禁用账号
  和无 NLA 的拒绝用例断言该标记不存在。对本项目当前仅启用的 bitmap 测试后端，
  这比只依赖 `bitmap_and_input_ok` 更直接地检查拒绝连接未收到 bitmap 更新。

## 验证

```sh
make check
make test-protocol
```

- `make check` 通过（Go race tests、go vet）。FreeRDP 头文件仍有两条上游弃用警告。
- `make test-protocol`：9/9 通过，40.494 秒，包括完全半开握手、X.224 后 TLS 停滞、
  慢读客户端写 deadline、合法认证 bitmap/键鼠回显及多种拒绝路径。
- TDD 红灯记录：TLS 停滞测试先在未修复代码上复现 18 秒 socket timeout；合法路径
  的 `bitmap_update_seen` 断言在遥测实现前失败；慢读用例在加入探针模式前因缺少
  deadline 事件标记失败。

## 剩余边界

- 未运行 Windows App / mstsc；未验证服务账号 + LaunchDaemon 环境。
- 超时取消仍依赖 FreeRDP/系统 socket 的 shutdown 能唤醒对应阻塞；回归测试覆盖当前
  macOS arm64 与固定 FreeRDP 3.32.2，不外推到其他平台/版本。
- BitmapUpdate 断言覆盖当前测试后端的 bitmap 更新；未来若启用 SurfaceBits、EGFX 或
  其他图形路径，拒绝路径测试需同时观测那些更新类型。
- 独立审计文件保留当时发现，不回写覆盖；本记录是其后续修复结果。
