# docs/archive — 历史文档（非权威）

本目录存放**已被当前代码与 STATUS 取代**的历史记录，仅用于追溯当时的现场、决策与证据。这里的内容是**历史证据**，不是操作指南。

- **当前权威入口**：[../STATUS-2026-11-08.md](../STATUS-2026-11-08.md)（状态 / 范围 / 测试基线）
- **最终验收**：[../VERIFICATION-2026-11-08-final-acceptance.md](../VERIFICATION-2026-11-08-final-acceptance.md)
- **全量目录索引**：[../README.md](../README.md)

## 目录内容

> 本文件不计入下表；本目录共 9 个 `.md`（1 个索引 + 8 份历史记录）。

| 文件 | 内容 |
| --- | --- |
| `PERFORMANCE-2026-11-07-frame-rate.md` | 帧率优化阶段的性能记录 |
| `PERFORMANCE-AVC420-IMPLEMENTATION.md` | AVC420 实验实现记录（未进入产品路径） |
| `performance-baseline.md` | 早期性能基线数据 |
| `RESOLUTION-ADAPTATION-2026-11-07.md` | 分辨率自适应实现与证据（布局/鼠标整数契约仍有效） |
| `VERIFICATION-2026-11-07-resolution-adaptation.md` | 分辨率自适应验收 |
| `VERIFICATION-2026-11-08-clipboard-files.md` | 文件剪贴板独立验证 |
| `VERIFICATION-2026-11-08-field-acceptance.md` | 真机现场验收 |
| `VERIFICATION-2026-11-08-regressions.md` | 集成回归（基线数字已被 STATUS §4 取代） |

## 使用须知

- 归档中的命令、路径、二进制 sha256、PID/generation 与“待办”**均已过期**，不要按它们操作正在服务的环境；当前事实以 [STATUS](../STATUS-2026-11-08.md) + 代码为准。
- 归档中仍然有效的安装/迁移/回滚与排障要点已并入 [README.md](../../README.md)、[AGENTS.md](../../AGENTS.md)、[STATUS](../STATUS-2026-11-08.md) 与 [DEPENDENCIES](../DEPENDENCIES.md)。
- 文档是历史证据：**新增而不是重写既有证据**；新增记录按 [docs/README.md](../README.md) 的命名规则放置。
