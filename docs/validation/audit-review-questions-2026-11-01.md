# 审计复核报告（问题 / Q）

日期：2026-11-01（Asia/Shanghai）。对照原始独立审计、当前源码和
audit-remediation-2026-11-01.md，独立复测；没有修改当前业务源码或测试。

## 验收意见

三项原始发现中，TLS 停滞修复及 bitmap 拒绝路径断言可接受；发送超时只完成
部分实现，不能认定全部修复验收通过。当前仍存在两个 P2 问题。

| 原始发现 | 复核结果 |
| --- | --- |
| TLS 阶段停滞超过 15 秒 | 原复现对应的回归通过；dup socket + listener watchdog 已能中止该等待 |
| 5 秒发送超时无执行机制 | 新增独立 watchdog，正常事件循环发帧有取消路径；RefreshRect 路径仍绕过 deadline，测试存在假阳性 |
| 拒绝认证测试没有独立画面断言 | 已新增 BitmapUpdate 遥测和对应断言，合法、拒绝路径复跑通过；范围限于当前 bitmap 后端 |

## [P2] 发送超时测试在关闭发送超时后仍然通过

位置：scripts/test-protocol.py:146–151；internal/worker/native.c:388–398。

mode 3 在收到初始帧、发送输入、Sleep(7000) 后，仅凭 announced、sent 和 frame
就输出 write_deadline_expired 并设 result=0，没有检查服务端 EOF、断开原因或超时
发生时间。随后 freerdp_disconnect 是客户端主动断开，不能证明服务端此前已关闭。

Python 测试从日志开头查找任意 peer_deadline_expired；前面的半开握手和 TLS 停滞
用例已产生同名事件，未限定本次连接或本次测试产生的日志。

独立故障注入验证：

1. 在 tempfile.TemporaryDirectory 中复制 cmd、internal、scripts 和 go.mod，
   通过符号链接复用当前 .deps；原项目源码保持原样。
2. 仅在副本把唯一的 job->deadline=GetTickCount64()+5000 改为
   job->deadline=UINT64_MAX，禁用事件循环发帧的超时，保留握手超时。
3. 在副本重新 go build -o bin/ ./cmd/...，运行完整 scripts/test-protocol.py。
4. 结果仍为 9 / 9 通过，41.609 秒，退出码 0。副本已自动清理。

因此完整测试通过不能证明发送超时生效，修复记录所称“客户端发现连接被关闭”
缺乏相应断言。原实现的发送取消代码已新增，但测试不能识别这段保护被移除。

建议：使用新 worker 或按连接 ID / 日志偏移隔离证据，制造确定的发送背压，
客户端实际观测服务端关闭，核对约 5 秒时间界限，并确认租约释放后能够重新连接。
禁用发送 deadline 时，该测试必须失败。

## [P2] RefreshRect 发帧没有设置 5 秒 deadline

位置：internal/worker/native.c:171–172、231–238。

refresh 回调直接执行 draw_pattern，而只在事件循环主动发送初始帧 / 输入回显时
设置发送 deadline。Activate 及正常发送结束后 deadline 都为 UINT64_MAX。
因此在已激活连接中请求 RefreshRect 后停止读取，若刷新发帧遇到背压，独立
watchdog 没有有限 deadline 可执行，peer 可能卡在 CheckFileDescriptor 的回调中，
占用唯一租约。此项来自调用路径核查，本轮没有对 RefreshRect 制造背压实测。

建议：将所有刷新请求汇总到有 deadline 的事件循环，或统一在发帧入口设置和清理
deadline，确保所有 draw_pattern 调用均受保护；增加刷新后停读的回归测试。

## 本轮命令与结果

- make check：通过；Go 测试命中缓存，go vet 通过。
- make test-protocol：重新构建，9 / 9 通过，39.136 秒。
- 单独运行 ProtocolTest.test_05c_blocked_frame_write_expires：通过，7.158 秒；
  新服务确实产生 deadline 日志，但客户端断开断言仍然缺失。
- 禁用发送超时的临时副本完整测试：9 / 9 通过，41.609 秒；确认存在测试假阳性。

测试均使用临时凭据和 loopback 服务，未变更系统设置、桌面权限或执行锁屏、注销、
重启。没有进行 Windows App、LaunchDaemon 或真实 macOS 桌面验收；P0 整体状态
仍保持原审计的“未完整完成”。本次只新增这份复核报告。
