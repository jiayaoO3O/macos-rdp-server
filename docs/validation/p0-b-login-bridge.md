# P0-B 登录窗口桥接：按当前范围暂缓

日期：2026-11-01，Asia/Shanghai。

## 本机结果

- Apple Silicon，16 GB；macOS 27.x。
- 当前控制台是已登录用户；不是登录窗口测试条件。
- `fdesetup status` 返回 `FileVault is Off.`。未更改 FileVault。
- `127.0.0.1:5900` 连接返回 `ECONNREFUSED`；未取得 RFB banner。
- `lsof -nP -iTCP:5900 -sTCP:LISTEN` 未返回监听项。
- `launchctl print-disabled system` 未提供屏幕共享/RemoteDesktop 的匹配条目，
  不能据此区分服务未启用、按需启动或其他配置状态。
- 未启用屏幕共享、Remote Login、自动登录；未注销、锁屏或重启。
- Tailscale.app 已安装；未验证其登录状态、启动方式、直连或中继行为。

结论：当前没有可连接的系统 RFB 后端。不能宣称已验证重启登录、解锁或桥接。
首阶段范围已确认：只支持本机登录后 RDP 控制当前桌面；因此此缺口目前不是 P0-C 的阻塞项。

## 候选依赖审查

[LibVNCClient 上游](https://github.com/LibVNC/libvncserver) 的认证表列出 Apple
ARD（security type 30），许可证为 GPL-2.0-or-later；上游也明确提醒链接程序的
许可证义务。[发布页](https://github.com/LibVNC/libvncserver/releases) 当前显示
0.9.15 为最新发布。以上是项目方资料，不能证明在本机 macOS 27 登录窗口可用。

因此目前只列为候选，没有下载、链接或引入该库。项目采用 Apache-2.0（见 `LICENSE`），
不引入 GPL-2.0-or-later 依赖；如仍需评估，先检查具体版本安全公告，并确认机器凭据方案
不会要求长期保存 macOS 用户密码。不能因为存在 ARD 认证支持就认为独立 VNC 密码一定能
控制登录窗口。

## 下一次实验的明确前提

1. 维护者允许启用系统屏幕共享，并选择测试专用的认证方式；不得复用或保管 Mac
   登录密码作为桥接的长期机器凭据。启用可能增加 5900 网络监听面。
2. 先准备可审查的网络限制方案，检查已有防火墙规则；经授权修改后，分别从
   loopback、局域网和 Tailscale 对监听面实测。不能默认系统服务只监听 loopback。
3. 保留本地恢复能力，另行取得执行锁屏、注销、重启的明确授权；这些动作会
   中断当前桌面工作，不能在本次开发中擅自进行。
4. 固定 RFB 库与认证模式后，首先在登录窗口获取并操作画面，再实现 RDP 桥接。
   按 PLAN.md 记录登录、锁屏、注销、登录期间断线，以及其他用户活动的结果。

如果需要长期存储 Mac 密码才能工作，或无法限制监听面，先记录失败并重新评估
候选方案。P0-C 的后端交接不得以此桥接已成功为前提。

## 2026-11-01 后续官方资料核对

- GitHub 最新 release API 仍指向 LibVNCServer/LibVNCClient 0.9.15（2024-12-22）。上游
  README 列出 LibVNCClient 支持 VNC Authentication（security type 2）和 Apple ARD
  （security type 30）；这只是库方支持声明，不证明它能在本机 macOS 27 登录窗口工作。
- 上游 README 声明 GPL-2.0-or-later，并明确表示链接使用会使程序成为衍生作品。仓库
  采用 Apache-2.0（见 `LICENSE`），因此不引入 GPL-2.0-or-later 依赖；候选实现需满足
  Apache-2.0 兼容的许可证策略。
- Apple 官方手册说明启用“屏幕共享”后，网络中其他电脑可查看并控制 Mac；可选择用户
  请求控制，或允许 VNC 查看器使用密码。屏幕共享与远程管理不能同时开启。因此必须
  先约定独立测试密码和网络限制，再实测 5900 监听面；不能假设只绑定 loopback。
- 本次只做文档核查，没有启用系统共享服务、改变防火墙或触发任何权限提示。

只有以后恢复“RDP 登录窗口/远程解锁”需求时，才需重新评估依赖许可证（当前 Apache-2.0 不接受
GPL-2.0-or-later）、授权临时开启屏幕共享并使用独立 VNC 测试密码检查监听面。不得使用或保存 Mac
锁屏密码作为桥接凭据。
