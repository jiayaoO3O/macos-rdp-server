# 验证：不改 FreeRDP 源码让 Worker 在 macOS 26 与 27 都可启动

日期：2026-11-09
相关：`docs/STATUS-2026-11-08.md` §1.2（macOS 26 SIGSEGV 结论与当前制品状态）

## 1. 问题回顾

macOS 26.5.1 上启动 worker 立即 SIGSEGV（`PC=0x0`、`signal arrived during cgo execution`），
栈固定为 `winpr_event_init → CreateEventA → freerdp_listener_open → rdp_serve`。

根因：WinPR 在 `WINPR_HAVE_PIPE2` 打开时调用 `pipe2()`；macOS 27 SDK 会为该调用产生
弱导入 `_pipe2`，而 macOS 26.5.1 的 libSystem 不导出该符号，弱导入槽为 NULL，调用即跳转到 0。
`minos=14.0` 只能声明“我可运行在 14+”，并不能让目标机凭空拥有新 API。

## 2. 本次结论

**不需要修改 FreeRDP 源码。** 只靠构建参数即可让 WinPR 走上游自带的
`pipe() + fcntl(FD_CLOEXEC)` 可移植路径，产物在 macOS 26 与 27 上都不会引用 `_pipe2`：

1. `-DCMAKE_OSX_SYSROOT=<显式 SDK>`：CMake 的 availability 探测
   （`-Werror=unguarded-availability-new`）会因为部署目标是 macOS 14 而拒绝 `pipe2`
   （`'pipe2' is only available on macOS 27.0 or newer`），自动把
   `WINPR_HAVE_PIPE2` 置空；用 macOS 26 SDK 时则是 `call to undeclared function 'pipe2'`。
2. `-DWINPR_HAVE_PIPE2=OFF`：即使将来 SDK 探测行为变化，也强制使用可移植路径。

之前的修复（在 `.deps/` 里手改 Event/Pipe/Semaphore 三个文件）功能上正确，但源码位于
gitignore 目录，干净 clone 无法复现，必须先手工重放补丁。本次改动把同等效果收敛到
`scripts/build-freerdp.sh` 的构建参数里。

## 3. 证据

### 3.1 使用官方 tar 包原版源码（未打任何补丁）

- 源码：`.deps/downloads/freerdp-3.32.2.tar.gz`，SHA-256
  `e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c`
- 解包到 `/tmp/rdp-pristine-src/freerdp-3.32.2`，确认三个文件仍保留 `WINPR_HAVE_PIPE2` 分支
  （event.c 1 处、pipe.c 1 处、semaphore.c 2 处；本地打过补丁的 `.deps` 副本为 0 处）。

### 3.2 macOS 26.5 SDK 构建（pristine）

| 项 | 结果 |
| --- | --- |
| `CMAKE_OSX_SYSROOT` | `.../SDKs/MacOSX26.sdk` |
| `WINPR_HAVE_PIPE2` | `INTERNAL=`（即关闭） |
| `winpr/config.h` | `/* #undef WINPR_HAVE_PIPE2 */` |
| `nm -u libwinpr3.3.dylib` | 无 `_pipe2` |
| `vtool -show-build` | `minos 14.0` / `sdk 26.5` |
| 原生 smoke（listener + CreateEventA） | `listener and WinPR event initialization succeeded` |
| loopback protocol 套件 | **35 项通过，1 项预期 skip**（约 98 s） |

### 3.3 macOS 27.2 SDK 构建（pristine）

同一份未改源码、`-DCMAKE_OSX_SYSROOT=MacOSX27.sdk`：

| 项 | 结果 |
| --- | --- |
| `WINPR_HAVE_PIPE2` | 关闭（探测因 deployment target 14.0 报可用性错误） |
| `nm -u libwinpr3.3.dylib` | 无 `_pipe2` |
| `vtool -show-build` | `minos 14.0` / `sdk 27.2` |

即同一套构建脚本在开发机（27.2）与目标机（26.5）两侧都不会生成弱导入。

### 3.4 App 打包

以 SDK 26 依赖前缀打包出候选 DMG（`FREERDP_INSTALL_PREFIX` 可指定）：

```
dist/RDPServer-0.2.2.dmg（尺寸/校验和以当次构建为准）
libwinpr3.3.dylib        minos 14.0 / sdk 26.5，无 _pipe2 导入
```

`scripts/test-app-bundle.py`：16 项通过；`--self-test starts service` 一项失败，原因是测试机
当时存在残留虚拟显示器（`event=display_inventory online=1 builtin=0 main=1`），
Agent 连续退出 4 次拿不到帧。SDK 26 与 SDK 27 两个变体表现**完全一致**，与本改动无关；
去掉该项后 `--skip-service-check` 全部通过（16 passed / 1 skipped）。

## 4. 构建用法

```sh
# 目标机兼容（推荐）：先装/选择 macOS 26 SDK 再构建依赖
MACOSX_SDK_ROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
  FREERDP_BUILD_DIR=.deps/build-macos26 \
  FREERDP_INSTALL_PREFIX="$PWD/.deps/install-macos26" \
  make deps
# 之后用同一前缀打包
FREERDP_INSTALL_PREFIX="$PWD/.deps/install-macos26" make app-dmg
```

不设置 `MACOSX_SDK_ROOT` 时使用 `xcrun --sdk macosx --show-sdk-path`（开发机当前 SDK），
因为 `-DWINPR_HAVE_PIPE2=OFF` 仍在，产物同样不含 `_pipe2`。
`make test-freerdp-sdk-selection` 守护上述构建参数与 CMake cache 断言。

## 5. 未验证 / 待确认

- 本候选 DMG **尚未**在真机 macOS 26.5.1 上点击“启用”复验；此前确认可用的是
  `.deps` 手工补丁版安装包。两者 WinPR 行为等价（都走 pipe fallback），但应以真机一次
  “启用 → 连接 → 断开”确认。
- `-DWITH_OPUS=OFF`：本机 Homebrew opus 的头文件路径探测失败会让干净构建中断；
  产品不使用 opus，故显式关闭。若将来需要 opus 通道需单独处理依赖发现。
