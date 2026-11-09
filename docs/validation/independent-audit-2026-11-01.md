# 独立安全核查

日期：2026-11-01（Asia/Shanghai）。范围：当前 PLAN.md、实现与验证记录。
本报告以当前磁盘文件和独立复测为准。

## 结论与阶段状态

当前 PLAN.md 没有单独的勾选进度表，以下对照第 1 节状态说明和第 7 节验收要求。

| 项目 | 独立核查结论 |
| --- | --- |
| P0-A loopback NLA、测试位图、键鼠回显 | 已实现；现有 7 个协议用例复跑通过，但超时保护和拒绝画面的测试断言存在缺口 |
| P0-A 完整验收 | 未完成；缺 Windows App / mstsc 验收、无 GUI 登录时的机器级凭据读取验证 |
| P0-B 登录桥接 | 未完成；只有前提核查记录，没有 RFB 客户端或 RDP 登录桥接实现 |
| P0-C 独立 Swift 探针 | 可构建，权限状态查询已复核；capture / move 有实现，实际采集和输入效果未验收 |
| P0-C 原生桌面与后端交接 | 未完成；缺 LaunchAgent、身份核验、IPC、连续帧、键盘输入、编码、后端切换和跨用户验证 |
| P1 / P2 / P3 | 未达阶段验收；配置、CLI 和单连接租约仅为局部基础能力 |

PLAN.md 第 1 节的保守范围说明基本属实，但“Go 主服务 + cgo FreeRDP Worker”容易
让人误以为已有独立监督进程。当前 cmd 中只有 rdp-worker、rdp-probe、rdpctl，
尚无设计中的 rdpd 主服务及 Worker 进程监督。

## 发现

### [P1] 15 秒握手截止时间不能中止停在 TLS 阶段的连接

位置：internal/worker/native.c:214–223。

deadline 仅在 peer 事件循环调用 CheckFileDescriptor 之前检查；如果该调用进入
上游 TLS 握手等待，外层不能再次检查时间。上游 crypto/tls.c 的 pollAndHandshake
使用 INFINITE 等待，项目没有独立中止机制。

独立复现：使用 scripts/test-protocol.py 的 ProtocolTest.setUpClass 创建临时
loopback 服务和凭据；连接后发送以下 X.224 / RDP 协商请求，然后不发送 TLS ClientHello：

```text
030000130ee000000000000100080003000000
```

服务返回选择 HYBRID 的响应：

```text
030000130ed000000000000209080002000000
```

随后 recv 设置 18 秒超时，实际超时而没有收到 EOF。测试结束关闭 socket 并清理
服务。由此确认“所有未完成握手均在 15 秒后关闭”不成立。代码限制最多四个 peer，
因此存在未认证连接长期占用槽位的风险（LAN 场景已知限制，需维护者评估；本轮未实测四槽耗尽）。
后续提交已修复 TLS/NLA 停滞的取消路径（见 [audit-remediation-2026-11-01.md](audit-remediation-2026-11-01.md)）；本段保留历史发现。

建议：使用能打断 FreeRDP 内部等待的独立取消机制，并添加协商后停在 TLS / NLA
阶段的回归用例；不能只测试建立 TCP 后完全不发数据。

### [P2] 文档声称的 5 秒发送超时没有有效执行

位置：internal/worker/native.c:227–235；native/freerdp/README.md:28–30。

发送前设置 deadline，随后在同一线程同步执行 draw_pattern，返回后直接把 deadline
改回 UINT64_MAX。调用阻塞期间没有其他线程检查或执行取消；即使调用超过 5 秒才
返回，也会在下一次检查前清除截止时间。文档中的 native watchdog 已不存在。
本结论来自代码核查，本轮没有制造发送背压；不能认定发送超时已验证完成。

建议：补有效的发送取消路径及不读取画面的客户端测试，并同步修正文档。

### [P2] 认证失败测试不足以证明“从未显示画面”

位置：scripts/test-protocol.py:92–100、125–128；internal/worker/native.c:350–359。

bitmap_and_input_ok 只在初始画面和键鼠回显均成功后输出。错误密码等用例仅检查
非零退出码及没有该标记，禁用账号只检查退出码；如果收到初始画面但没有回显，
这些断言仍可能通过。因此验证记录中的“不出现测试画面”超出了测试直接观测范围。
当前代码在 draw_pattern 前检查 leased 和 ready，本轮未发现实际认证绕过或画面泄露。

建议：探针单独报告认证结果和收到的任何 bitmap / 首帧事件，所有拒绝路径断言
零画面，并区分预期拒绝与一般客户端错误。

## 本轮独立验证

- make check：通过（Go race 测试与 go vet；部分 Go 测试命中缓存）。
- make test-protocol：7 / 7 通过，16.983 秒；包含重新构建 Go 二进制。
- FreeRDP 发布包 SHA-256：与脚本固定值一致；未重新下载或检查最新安全发布。
- make agent-check：将 CLANG_MODULE_CACHE_PATH 和 SWIFT_MODULECACHE_PATH 指向
  仓库 .cache 后通过。
- make agent-build：通过，有两条 Developer 路径 linker 警告。
- bin/rdp-agent status：screen_recording=missing accessibility=missing desktop_ready=false。
- 额外 TLS 停滞用例：失败，18 秒后连接仍未关闭（见 P1 发现）。

初次协议测试被沙箱禁止 bind；在允许 loopback 网络的执行环境重试通过。
Swift 初次因默认缓存写入和 SwiftPM 嵌套沙箱限制失败，重定向缓存并在允许构建的
执行环境重试通过。未更改隐私设置、采集屏幕、注入输入、启用系统服务或执行锁屏、
注销、重启。本次只新增核查报告，未修改业务实现和原进度说明。

验收意见：认可“有限 loopback 原型 + 独立 Swift 探针”成果；不批准将 P0-A、P0-B、
P0-C 任一阶段整体标为完成。先修复和补测超时保护，再补主要客户端及系统场景验收。
