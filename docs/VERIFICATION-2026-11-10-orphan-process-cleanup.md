# VERIFICATION — Worker orphan-process cleanup (2026-11-10)

> 工作树：`orphan-process-cleanup`（基于 `main` `0a06ecb`）。本记录只覆盖 Worker/App
> 生命周期清理；不改变 RDP 协议、输入、剪贴板或采集路径。

## 1. 背景

上一轮改动把 `ServerManager.workerStopGrace` 从 5s 提高到 10s，并增加自检
`cleanup.worker_grace_exceeds_supervisor_grace`，用于避免 App 在 `address:auto`
监督进程停止其 FreeRDP 子进程（最多 5s）之前把 Worker SIGKILL 掉。

复查发现该修复只覆盖了“正常停止”一条路径，仍有遗漏：

1. 启动就绪失败时只给 Worker 2s、`deinit` 只给 1s——同样会提前 SIGKILL 监督进程，
   遗留 FreeRDP 子进程继续监听 3389。
2. App 被 `SIGKILL`/崩溃时，`rdp-worker`（以及 `address:auto` 的 FreeRDP 子进程）
   会成为孤儿；文档声称“core 下次启动的残留清理”，但代码中没有该实现。
3. 点击“启动”时没有查询/清理上一轮崩溃遗留的 Worker；旧进程仍占着 3389 与
   `agent.sock` 时，新 Worker 会启动失败（或 C listener 静默放弃）。
4. `address:auto` 监督进程在子进程崩溃/被 SIGTERM 后重启时没有 unlink 旧
   `agent.sock`；C listener 检测到路径存在会静默放弃监听（`reason=no_frame`）。
5. Worker 意外退出时只给 Agent 2s 终止宽限，可能来不及恢复显示排列。

## 2. 本次改动

| 位置 | 改动 |
| --- | --- |
| `native/macos/Sources/RDPServerCore/WorkerLease.swift`（新增） | 记录 `pid + start time + executable path` 的 0600 lease；启动时校验身份（防 PID 复用）后 SIGTERM，超时再 SIGKILL；`/bin/ps` 回退扫描同一 `-config <config.json>` 的 `rdp-worker`，覆盖旧版本/lease 写失败场景 |
| `native/macos/Sources/RDPServerCore/ServerPaths.swift` | 新增 `<data>/worker.lease` 路径与删除方法 |
| `native/macos/Sources/RDPServerCore/ServerManager.swift` | `startNow()` 在 spawn 前执行 `StaleWorkerCleanup`；spawn 后立即写 lease；正常停止、启动失败、`deinit`、Worker 意外退出均删除 lease；新增 `lanSupervisorStopGrace = 5`（镜像 `cmd/rdp-worker` 的 `stopChild`）；所有 Worker 终止路径使用 `workerStopGrace`；Worker 意外退出时 Agent 使用 `agentStopGrace`；App 拉起 Worker 时设置 `RDP_WORKER_MANAGED_BY_APP=1` |
| `cmd/rdp-worker/main.go` | 新增父进程看门狗：`address:auto` 监督进程每 500ms 检查 `getppid()==1`，父进程消失后记录 `event=worker_parent_exited`、取消上下文并停止子进程；普通 Worker 直接 `os.Exit(0)`。手工/launchd 形态不带该环境变量，生命周期不变 |
| `cmd/rdp-worker/main.go` | `address:auto` 在每次启动子进程前 unlink `agent.sock`（失败记 `event=lan_socket_remove_failed`），停止时也 unlink；修复子进程重启后的 stale socket |
| `native/macos/Sources/RDPServerCore/SelfTest.swift` | 新增 stale Worker seed/lease/scan/remove 检查；自检详情使用 `lanSupervisorStopGrace`，不再硬编码 5 |
| `scripts/test-app-core.py` | 默认 `--self-test` 要求清理检查；`--with-service` 额外要求 stale Worker 的 seed/lease/scan/remove/lease-source 全通过 |
| `scripts/test-worker-auto-lan.py` | 新增 2 例：父进程死亡后受管 Worker 自动退出；子进程被 SIGKILL 后监督进程重启并重建 `agent.sock` |

## 3. 验证（本机，Apple Silicon / macOS 27.2 构建工具链）

```sh
# Go 编译/vet（使用主仓库 .deps 的隔离 symlink）
go build -o bin/rdp-worker ./cmd/rdp-worker
go build -o bin/rdpctl ./cmd/rdpctl
go vet ./cmd/rdp-worker

# address:auto 三例：正常停止、父进程死亡、子进程重启重建 socket
python3 scripts/test-worker-auto-lan.py -v
# -> Ran 3 tests ... OK

# App core：无服务自检 + 隔离 Worker/Agent 生命周期
python3 scripts/test-app-core.py
python3 scripts/test-app-core.py --with-service
# -> ALL TESTS PASSED（含 cleanup.stale_worker_seeded/lease/scan/removed/lease_source）

# App 构建
swift build -c release --package-path native/macos

# 回归（未改协议，但确认 Worker 启动路径无回归）
make check                 # Go race/vet + C gfx 14 例 + AVC encoder 2 例
make test-protocol         # 35 例 OK（1 例 AVC420 skip），~95s
```

本机没有正在服务的 RDP 会话，测试使用临时目录/随机端口；未触碰 `.runtime/`、`bin/`
或 `dist/`（工作树内的 `bin/` 为隔离构建产物，`.deps` 指向主仓库）。

## 4. 未验证 / 剩余风险

- **真机 App SIGKILL 后立即重开**：启动清理会在 spawn 前按 lease/scan 终止旧
  Worker 并等待进程退出，自动化已覆盖；但尚未在真实菜单栏 App 上做“SIGKILL
  后立即重开并点启动”的人工体验验收。
- 未跑 `make test-virtual-display`（会短暂改真实显示排列；本次未触碰显示器路径）。
- 未在 Windows `mstsc.exe` 真机验证；本次改动不触碰 RDP 协议与画面路径。
- DMG bundle 校验见下一节；版本 0.2.3 的成品尚未真机安装验收。

## 5. 版本与打包（0.2.3）

- `Version.swift`、`package-app-dmg.py`、`test-app-bundle.py`、`test-app-core.py`
  以及当前面文档同步为 **0.2.3**（`0.2.2 → 0.2.3`）。
- `make app-dmg` 成功：`dist/RDPServer-0.2.3.dmg`，11,615,178 B，
  sha256 `12a15e0ca1bcb53a9903d833da82c01d3e66c1de0125ab03113ec70f219312f8`。
- `make test-app-bundle` 通过：18 passed / 0 failed；Info.plist 0.2.3 (build 1)，
  nested Agent 0.2.3，7 个 dylib @rpath 重定位，许可证三件套，`rdp-worker`
  临时配置启动/停止，`--self-test` 29 checks，`--self-test` 启动服务并清理通过。
- 该 DMG 为 ad-hoc 签名；安装后 TCC（屏幕录制/辅助功能）可能需要重新授权。
