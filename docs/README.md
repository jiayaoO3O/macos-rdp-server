# docs/ 文档索引

> 本目录存放项目的**设计 / 诊断 / 验证 / 阶段验收 / 历史归档**记录。文档是历史证据：**新增记录，不重写既有证据**；已被取代的结论以 [STATUS-2026-11-08.md](STATUS-2026-11-08.md) 与当前代码为准。

## 权威入口（先读这些）

| 文档 | 定位 | 说明 |
| --- | --- | --- |
| [../README.md](../README.md) | 项目入口 | 面向人类：目标、构建、运行、测试与客户端验证 |
| [../AGENTS.md](../AGENTS.md) | **唯一 AI 代理入口** | 项目纪律、契约、命令、常见陷阱（开工前必读） |
| [../PLAN.md](../PLAN.md) | 历史规划 | 早期方案记录；不是当前实现说明或任务清单 |
| [STATUS-2026-11-08.md](STATUS-2026-11-08.md) | **当前状态权威** | 实现状态、可用范围、测试基线、运行态；状态冲突时以此为准 |
| [DEPENDENCIES.md](DEPENDENCIES.md) | 依赖与版本 | 版本矩阵、构建顺序、第三方许可证与可复现性边界 |

## 命名规范

- 常规文档：`CATEGORY-YYYY-MM-DD[-slug].md`，`CATEGORY` ∈ `DESIGN` / `DIAGNOSIS` / `PERFORMANCE` / `VERIFICATION` / `STATUS`。不再新增交接类文档；状态写入 STATUS，历史证据写入 VERIFICATION / DIAGNOSIS。
- 例外：`docs/README.md`、`docs/archive/README.md` 等目录索引文件；`docs/archive/` 保留历史文件名（如 `performance-baseline.md`、`PERFORMANCE-AVC420-IMPLEMENTATION.md`、`RESOLUTION-ADAPTATION-2026-11-07.md`），不强制日期格式。
- 阶段验收记录放 `docs/validation/`；被取代但仍需追溯的记录放 `docs/archive/`。
- 改动行为 / 命令 / 范围时，同步更新 `STATUS`、`README`、`AGENTS` 中对应段落；文档之间用相对链接互引。

## 分类索引

### 状态与总览

| 文档 | 主题 |
| --- | --- |
| [STATUS-2026-11-08.md](STATUS-2026-11-08.md) | 当前实现状态、测试基线、已知限制（**权威**） |
| [DEPENDENCIES.md](DEPENDENCIES.md) | 依赖/版本矩阵、构建与打包、第三方许可、可复现性 |

### 设计（DESIGN）

| 文档 | 主题 |
| --- | --- |
| [DESIGN-2026-11-07-resolution-adaptation.md](DESIGN-2026-11-07-resolution-adaptation.md) | 客户端分辨率适配、采集策略、fit-with-bars 整数算法 |
| [DESIGN-2026-11-08-clipboard-files.md](DESIGN-2026-11-08-clipboard-files.md) | 文件剪贴板双向实现与绑定契约（含安全要求、测试清单） |
| [DESIGN-2026-11-08-app-packaging.md](DESIGN-2026-11-08-app-packaging.md) | 菜单栏 App/DMG 打包、dylib 重定位、ad-hoc 签名与校验 |
| [DESIGN-2026-11-08-menu-bar-app.md](DESIGN-2026-11-08-menu-bar-app.md) | 菜单栏 App 架构、生命周期、权限、自检与 CLI |
| [DESIGN-2026-11-08-menu-bar-ui.md](DESIGN-2026-11-08-menu-bar-ui.md) | 菜单栏 UI 布局、交互状态与截图/自动化验证 |
| [DESIGN-2026-11-08-virtual-display.md](DESIGN-2026-11-08-virtual-display.md) | 16:9 虚拟显示器会话、镜像采集与显示排列恢复 |

### 诊断（DIAGNOSIS）

| 文档 | 主题 |
| --- | --- |
| [DIAGNOSIS-2026-11-08-disp-window-resize.md](DIAGNOSIS-2026-11-08-disp-window-resize.md) | Windows App 客户端不发送 DISP monitor layout 的定位 |
| [DIAGNOSIS-2026-11-08-keyboard-swallowed-input.md](DIAGNOSIS-2026-11-08-keyboard-swallowed-input.md) | 键鼠输入被吞/Fn 位继承问题的根因与修复证据 |
| [DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md](DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md) | 虚拟显示器激活时鼠标坐标偏移的根因与修复验证 |

### 验证（VERIFICATION）

| 文档 | 主题 |
| --- | --- |
| [VERIFICATION-2026-11-08-final-acceptance.md](VERIFICATION-2026-11-08-final-acceptance.md) | 真实 Windows 11 客户端（mstsc）最终验收记录 |
| [VERIFICATION-2026-11-09-macos26-sdk-build.md](VERIFICATION-2026-11-09-macos26-sdk-build.md) | macOS 26 SDK / WinPR pipe2 构建验证 |

### 阶段验收（docs/validation/，早期历史）

早期阶段（P0-A / P0-B / P0-C 与审计）的验收记录，**结论可能已被 STATUS 取代**，仅作追溯：

- [p0-a-2026-11-01.md](validation/p0-a-2026-11-01.md)、[p0-b-login-bridge.md](validation/p0-b-login-bridge.md)、[p0-c-agent-probe.md](validation/p0-c-agent-probe.md)
- [audit-remediation-2026-11-01.md](validation/audit-remediation-2026-11-01.md)、[audit-review-questions-2026-11-01.md](validation/audit-review-questions-2026-11-01.md)、[audit-review-answers-2026-11-01.md](validation/audit-review-answers-2026-11-01.md)、[independent-audit-2026-11-01.md](validation/independent-audit-2026-11-01.md)

### 历史归档（docs/archive/）

> **归档 = 已被取代，仅用于追溯当时的现场、决策与证据。** 其中的命令、路径、二进制 sha256、PID/generation 与“待办”均已过期，**不要按它们操作线上环境**；当前事实以 STATUS + 代码为准。

当前主仓库没有交接类文档。历史目录中的阶段材料仍保留作证据，不应被当作当前任务清单。

| 文档 | 主题 |
| --- | --- |
| [archive/README.md](archive/README.md) | 归档目录说明与过期声明 |
| [archive/RESOLUTION-ADAPTATION-2026-11-07.md](archive/RESOLUTION-ADAPTATION-2026-11-07.md) | 分辨率适配阶段的完整推理与证据 |
| [archive/PERFORMANCE-2026-11-07-frame-rate.md](archive/PERFORMANCE-2026-11-07-frame-rate.md) | 帧率优化阶段基线记录 |
| [archive/PERFORMANCE-AVC420-IMPLEMENTATION.md](archive/PERFORMANCE-AVC420-IMPLEMENTATION.md) | AVC420 实验实现记录（默认产品不含） |
| [archive/performance-baseline.md](archive/performance-baseline.md) | 早期性能基线数据 |
| [archive/VERIFICATION-2026-11-07-resolution-adaptation.md](archive/VERIFICATION-2026-11-07-resolution-adaptation.md) | 分辨率适配阶段验证 |
| [archive/VERIFICATION-2026-11-08-clipboard-files.md](archive/VERIFICATION-2026-11-08-clipboard-files.md) | 文件剪贴板验证 |
| [archive/VERIFICATION-2026-11-08-field-acceptance.md](archive/VERIFICATION-2026-11-08-field-acceptance.md) | 真机现场验收（历史） |
| [archive/VERIFICATION-2026-11-08-regressions.md](archive/VERIFICATION-2026-11-08-regressions.md) | 回归验证（历史） |
