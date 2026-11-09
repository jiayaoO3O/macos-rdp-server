# RDPServer.app 打包与 DMG 分发设计（2026-11-08）

> **2026-11-09 补充（最低系统版本）**：交付要求是 **macOS 14.0+**（目标机器可能是 macOS 26，开发机更新）。
> `scripts/build-freerdp.sh` 以 `CMAKE_OSX_DEPLOYMENT_TARGET=14.0` 构建；Go+cgo helper 用 `-mmacosx-version-min=14.0`；
> `package-app-dmg.py` 在签名前用 `vtool` 把包内第三方 dylib（Homebrew OpenSSL/json-c）minos 归一化到 14.0；
> 若嵌套 Agent 的 minos 高于 14.0 则直接失败。打包完成后应审计所有 `Contents/**` Mach-O 的 `minos`。

> 状态：打包链路已实现并在本机端到端验证（2026-11-08 首次；2026-11-09 增补许可证随附与对应校验）：
> DMG 可挂载，bundle 脱离仓库独立运行，菜单栏 app 的 --status / --self-test
> 在挂载的只读 DMG 上返回 JSON。bundle 校验项数以 `test-app-bundle.py` 动态计数为准（默认 17 项；
> `--skip-service-check` 时 16 passed + 1 skipped），共享工作区里 .runtime 一项偶发 WARN、不归因于 app。
> 若 helper 路径/CLI/许可证文件变化，需复跑 `make app-dmg && make test-app-bundle`（见 §8）。
>
> 关联文档：[DESIGN-2026-11-08-menu-bar-app.md](DESIGN-2026-11-08-menu-bar-app.md)（app-core）、
> [DESIGN-2026-11-08-menu-bar-ui.md](DESIGN-2026-11-08-menu-bar-ui.md)（app-ui）、
> [AGENTS.md](../AGENTS.md) §3/§6、[docs/STATUS-2026-11-08.md](STATUS-2026-11-08.md)。
>
> 相关文件：scripts/package-app-dmg.py（新增）、scripts/test-app-bundle.py（新增）、
> scripts/package-agent-app.py（扩展为可复用）、Makefile（app-build / app-dmg / test-app-bundle）。

---

## 1. 目标与边界

目标：产出**拖拽安装**的 DMG —— 挂载后把 RDPServer.app 拖到 Applications，
在**没有仓库、没有 .deps/、没有 Homebrew** 的机器上也能启动菜单栏 app，
并由 app 启动自带的 Go Worker / rdpctl / 嵌套 Agent；包内同时随附
`LICENSE`/`NOTICE`/`THIRD-PARTY-NOTICES.md`（见 §3.1）。

非目标（P0 边界，见 PLAN.md §1、AGENTS.md §1）：

- 不做 Developer ID 稳定签名 / 公证 / 安装器（installer pkg）/ 系统 LaunchDaemon；
- 不替代 make build / make agent-build / make agent-app，**绝不写入 bin/**
  （现有部署产物）；打包产物只写 dist/（已 gitignore）；
- 不在 DMG 内放置任何凭据、配置、日志或用户数据。

构建与测试均使用本机已有工具链（Go 1.27、Swift 6.x、Xcode CLT、/usr/bin/python3），
**不引入新的外部依赖**（Python 仅标准库；Swift 仅 stdlib/Apple 框架；Go 仅 stdlib）。

---

## 2. 产物

| 路径 | 说明 |
| --- | --- |
| `dist/RDPServer.app` | 完整 app bundle（见 §3 布局） |
| `dist/RDPServer-0.2.2.dmg` | drag-install DMG（RDPServer.app + Applications 符号链接）；文件名版本以 `package-app-dmg.py` 的 `VERSION`（当前 0.2.2）为准 |
| `dist/build/` | 本次 `go build -o dist/build/ ./cmd/...` 的 Go 产物（rdp-worker、rdpctl 等） |
| `dist/dmg-staging/` | DMG 暂存目录（RDPServer.app + Applications -> /Applications） |

dist/ 已加入 .gitignore；所有这些都可以随时删除重建。

---

## 3. Bundle 布局契约

```
dist/RDPServer.app/
  Contents/
    Info.plist                     主 app 身份（见下表）
    MacOS/RDPServer                SwiftPM release 产品 RDPServer
    Helpers/
      rdp-worker                   Go 构建的 Worker（cgo + FreeRDP）
      rdpctl                       Go 构建的 rdpctl（hash-stdin）
      RDPAgent.app/                嵌套 Agent bundle（TCC 身份）
        Contents/
          Info.plist               CFBundleIdentifier = com.rdp-server.agent
          MacOS/rdp-agent          SwiftPM release 产品 rdp-agent
    Frameworks/                    所有非系统动态库（见 §5）
      libfreerdp-server3.3.dylib
      libfreerdp-client3.3.dylib
      libfreerdp3.3.dylib
      libwinpr3.3.dylib
      libssl.3.dylib
      libcrypto.3.dylib
      libjson-c.5.dylib
    Resources/
      AppIcon.icns                 菜单栏 App 图标（CFBundleIconFile=AppIcon）
      Licenses/                    许可证随附（见 §3.1）
        LICENSE
        NOTICE
        THIRD-PARTY-NOTICES.md
    _CodeSignature/                codesign 资源封印
```

主 app Contents/Info.plist（scripts/package-app-dmg.py:info_plist()）：

| key | 值 | 说明 |
| --- | --- | --- |
| CFBundleIdentifier | com.rdp-server.server | 固定契约 |
| CFBundleName / CFBundleDisplayName | RDP Server | 菜单栏/关于面板显示名 |
| CFBundleExecutable | RDPServer | 必须与 Contents/MacOS/RDPServer 同名 |
| CFBundleShortVersionString | 0.2.2 | 与 DMG 文件名一致（`VERSION` 常量） |
| CFBundleVersion | 1 | |
| LSMinimumSystemVersion | 14.0 | 与 SwiftPM platforms: [.macOS(.v14)] 一致 |
| LSUIElement | true | 菜单栏常驻、无 Dock 图标 |
| NSHighResolutionCapable | true | |
| CFBundlePackageType | APPL | |
| CFBundleIconFile | AppIcon | 对应 Contents/Resources/AppIcon.icns（自绘寻呼机图标；由 `scripts/generate-app-icon.py` 生成） |
| LSApplicationCategoryType | public.app-category.utilities | 可选 |

嵌套 RDPAgent.app 由 scripts/package-agent-app.py 生成（打包脚本直接复用 package_agent()）：
CFBundleIdentifier=com.rdp-server.agent、CFBundleExecutable=rdp-agent、LSUIElement=true、
CFBundleShortVersionString 与主 app 相同（0.2.2）。

**Helper 查找契约**（app-core / app-ui 实现）：

- 打包运行态：Bundle.main.bundleURL/Contents/Helpers/{rdp-worker,rdpctl,RDPAgent.app/Contents/MacOS/rdp-agent}；
- 测试覆盖：RDPSERVER_HELPERS_DIR 可整体覆盖 Helpers 目录（见 app-core 设计文档）；
- 开发态（直接跑 native/macos/.build/release/RDPServer）回退到仓库 bin/（仅开发）。

数据目录契约（app-core）：--data-dir PATH > RDPSERVER_DATA_DIR > 默认
~/Library/Application Support/RDPServer。DMG 安装后不需要任何仓库路径。

### 3.1 许可证随附（Contents/Resources/Licenses/）

`scripts/package-app-dmg.py::copy_license_files(contents)` 在 `assemble_app()` 中、**签名之前**把仓库根的三份文件复制到 `Contents/Resources/Licenses/`（逐字节复制并校验 sha256）：

| 文件 | 作用 |
| --- | --- |
| `LICENSE` | 项目自身 Apache-2.0 全文。Apache-2.0 §4(a) 要求向接收者分发作品时随附许可证副本 |
| `NOTICE` | 项目 NOTICE；Apache-2.0 §4(d) 要求保留其中的归属/声明信息（若存在） |
| `THIRD-PARTY-NOTICES.md` | 第三方组件归属与许可证汇总：FreeRDP/WinPR 与 OpenSSL（Apache-2.0）、json-c（MIT）、Go runtime（BSD-3-Clause）等；满足 MIT/BSD “保留版权与许可声明”义务 |

规则与失败模式：

- 三份源文件任一缺失或为 0 字节 → 打包**硬失败**（`missing/empty license file`）；复制后再检查目标文件非空，并比较 `sha256(source) == sha256(target)`，不一致同样硬失败（防止截断/混入旧文件）。成功时日志打印每个文件的字节数与 sha256 前缀（`license: Licenses/<name> (<n> bytes, sha256 <12 hex>…)`）。
- **必须在 `sign_bundle()` 之前完成**：代码签名覆盖 `Contents/Resources`，签名后再改 bundle 会使签名失效；每次打包从空 bundle 重建（`assemble_app()` 先删除旧目录），因此复制是幂等的。
- 验证侧（§8 的 `license files` 项）不写死期望值：以**当前仓库根**的同名文件为基准，逐个检查 shipped 副本存在、大小不小于源文件、`sha256` 与源文件一致，并断言关键标记（`LICENSE`：`Apache License`/`Version 2.0`/`END OF TERMS AND CONDITIONS`；`NOTICE`：`FreeRDP`/`OpenSSL`/`json-c`/`Go runtime`；`THIRD-PARTY-NOTICES.md`：`MIT`/`BSD-3-Clause`/`Apache-2.0`，以及构建锁定的 FreeRDP 版本号）。这样同时覆盖“拷贝被截断”“包内还是旧许可证”“文档说随附但实际没打进包”三类回归。

---

## 4. 命令

```sh
make app-build        # swift build -c release --package-path native/macos（只写 native/macos/.build）
make app-dmg          # app-build + python3 scripts/package-app-dmg.py（含 Go 构建到 dist/build/）
make test-app-bundle  # python3 scripts/test-app-bundle.py（缺 DMG 时自动打包）
```

直接调用脚本时：

```sh
python3 scripts/package-app-dmg.py                 # 复用已构建的 Swift 产物；重新构建 Go helper
python3 scripts/package-app-dmg.py --swift-build   # 先 swift build（等价 make app-dmg）
python3 scripts/package-app-dmg.py --skip-go-build # 复用 dist/build/ 里的 Go 产物
python3 scripts/package-app-dmg.py --skip-dmg      # 只组装+签名 app，不出 DMG

python3 scripts/test-app-bundle.py [--no-build] [--keep] [--dmg PATH]
```

要点：

- make app-dmg 需要 .deps/install（cgo 链接 FreeRDP）与 Go/Swift 工具链；**不联网**、不跑 make deps；
- 打包脚本**不读不写 bin/**，也不碰 .runtime/；Go helper 构建输出固定为 dist/build/；
- make test-app-bundle 只在临时目录里跑打包后的东西，不启动 3389、不读写现有服务数据（§8）。

---
## 5. 动态库重定位（dylib relocation）

### 5.1 问题

go build（cgo）链接 internal/worker/worker.go 里写死的 -L${SRCDIR}/../../.deps/install，产物因此带有：

- @rpath/libfreerdp-server3.3.dylib、libfreerdp-client3.3.dylib、libfreerdp3.3.dylib、
  libwinpr3.3.dylib（.deps/install/lib，install name 已是 @rpath/...）；
- LC_RPATH = <repo>/internal/worker/../../.deps/install/lib（绝对仓库路径）；
- FreeRDP/OpenSSL/json-c 内部还引用 **Homebrew 绝对路径**：
  /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib、libcrypto.3.dylib、
  /opt/homebrew/opt/json-c/lib/libjson-c.5.dylib；libssl.3 还引用
  /opt/homebrew/Cellar/openssl@3/3.5.9/lib/libcrypto.3.dylib（Cellar 绝对路径）。

### 5.2 算法（scripts/package-app-dmg.py）

1. **收集**：从 Contents/Helpers/rdp-worker、Contents/Helpers/rdpctl（以及嵌套 agent
   可执行文件）出发，BFS 遍历 otool -L 依赖；
   - 系统依赖（/usr/lib/、/System/、/Library/Apple/）跳过；
   - @rpath/<name>：先在 .deps/install/lib 找，再在已复制的 Contents/Frameworks 找；
   - 绝对路径（Homebrew/Cellar/其他）：直接作为源文件；
   - 以 **basename** 去重；同名不同内容（sha256 不同）直接报错，避免静默混用。
2. **复制**：全部复制到 Contents/Frameworks/<basename>（shutil.copy2 跟随符号链接，
   复制真实文件，权限 0755）。
3. **改写**（install_name_tool）：
   - helper（rdp-worker/rdpctl）：所有非系统依赖 -change <dep> @rpath/<basename>；
     -delete_rpath 删除仓库 .deps rpath；-add_rpath @executable_path/../Frameworks
     （helper 位于 Contents/Helpers/，../Frameworks = Contents/Frameworks）。
   - 每个 Framework dylib：绝对 install id 改 @rpath/<basename>；内部非系统依赖同样改
     @rpath/<basename>（覆盖 libssl→Cellar libcrypto 这类绝对引用）。
4. **去掉本机工具链 rpath**：Swift 产物带着
   /Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx；目标机可能没装 CLT，
   该路径无用（Swift 运行时依赖是绝对 /usr/lib/swift/...），因此从 RDPServer 与嵌套
   rdp-agent 中删除。嵌套 agent 二进制被修改后，用其**自己的** identifier/requirements
   重新 ad-hoc 签名（com.rdp-server.agent），保证 TCC 身份不被外层签名覆盖。
5. **重签**：所有被 install_name_tool 改过的 Mach-O（helpers、Frameworks dylib）都必须
   codesign --force --sign - 重新 ad-hoc 签名，否则 arm64 加载会失败。

### 5.3 结果（历史构建实测；数字随依赖/源码重建变化）

```
Contents/Frameworks: 7 个 dylib（10,609,888 bytes），install id 全部 @rpath/<basename>
rdp-worker / rdpctl: LC_RPATH 仅 @executable_path/../Frameworks（仓库 .deps rpath 已删除）
RDPServer / rdp-agent: LC_RPATH 仅 /usr/lib/swift、@loader_path（CLT rpath 已删除）
```

otool -L 检查：11 个 Mach-O（主可执行、2 个 helper、7 个 dylib、嵌套 agent）的
**所有非系统依赖都是 @rpath/<basename>，且都能在 Contents/Frameworks 中找到**；
没有任何 /opt/homebrew/...、仓库 .deps/... 或 /Library/Developer/... 绝对路径。

### 5.4 加新依赖时

若将来 Worker/Agent 增加新的非系统动态库，打包脚本的 BFS 会自动收集；需要保证的是
新库的依赖要么是系统库，要么能被 @rpath（.deps/install/lib 或 Frameworks）或绝对路径
找到。相对路径（@loader_path/@executable_path）依赖也支持解析。若同名库存在多份，
脚本会因 sha256 不一致而失败，需要人工决定保留哪一份。

---

## 6. 签名与 TCC 身份

签名顺序（**nested-first**，scripts/package-app-dmg.py:sign_bundle()；许可证文件已在 §3.1 于签名前复制）：

1. 嵌套 RDPAgent.app：scripts/package-agent-app.py 以
   codesign --force --sign - --identifier com.rdp-server.agent
   --requirements '=designated => identifier "com.rdp-server.agent"' 签名
   （TCC 身份 = bundle id + cdhash）；
2. 被 install_name_tool 修改的 helpers 与 Frameworks dylib：逐个 codesign --force --sign -；
3. 外层 RDPServer.app：codesign --force --sign - <app>（**不使用 --deep**）——
   --deep 会递归重签嵌套代码并按外层身份重写 identifier，可能破坏嵌套 agent 的
   TCC 身份；嵌套代码此时已各自签好，外层只签 main executable + bundle；
4. 验证：codesign --verify --deep --strict --verbose=2 dist/RDPServer.app，并断言
   codesign -dvv 显示外层 Identifier=com.rdp-server.server、嵌套
   Identifier=com.rdp-server.agent。

说明：

- 全部为 **ad-hoc 签名**（--sign -），**未公证、无 Developer ID**；没有启用
  hardened runtime / entitlements（ad-hoc 下无实际意义，留待生产签名阶段）。
- 每次重新打包 cdhash 都会变化：TCC（屏幕录制 / 辅助功能 / 完全磁盘访问）可能
  重新弹窗或需要重新授权。这是 P0 已知限制，不是打包 bug；生产化需要稳定
  Developer ID 签名，届时把 §6 的 ad-hoc 换成 codesign --sign "Developer ID Application: ..." +
  notarytool + stapler，并补 hardened runtime/entitlements。
- 嵌套 agent 的 bundle id 与 bin/RDPAgent.app 相同；TCC 按「bundle id + 路径/身份」记录，
  实测新 DMG 的嵌套 agent 复用了已有授权（rdp-agent status -> granted），
  但**不保证**在其它机器/路径上自动复用；验证脚本只把该状态作为信息输出，不要求 TCC 已授权。
- app 被拖到 /Applications 后，若它通过自身（而非嵌套 agent）身份请求权限，TCC 可能记录到
  com.rdp-server.server 而不是 com.rdp-server.agent。当前设计约定：权限（屏幕录制/辅助功能）
  归嵌套 RDPAgent.app；该行为依赖 app-core/app-ui 的启动方式，**真机验收通过**（2026-11-08/09，打包 App 连接测试；见 [VERIFICATION-2026-11-08-final-acceptance.md](VERIFICATION-2026-11-08-final-acceptance.md)）。

---

## 7. DMG

```sh
# scripts/package-app-dmg.py:create_dmg()
dist/dmg-staging/RDPServer.app                  # 从 dist/RDPServer.app 复制
dist/dmg-staging/Applications -> /Applications  # 绝对符号链接
hdiutil create -volname "RDP Server" -srcfolder dist/dmg-staging \
  -fs HFS+ -format UDZO -ov dist/RDPServer-0.2.2.dmg
hdiutil verify dist/RDPServer-0.2.2.dmg
```

- 卷名 RDP Server；DMG 内只有 RDPServer.app 与 Applications 符号链接，
  用户把 app 拖到 Applications 即完成安装；
- 优先可复现/简单：**没有**背景图、.DS_Store、自定义窗口尺寸/图标位置；
- 打包脚本打印 DMG 大小与 sha256，便于分发核对；本文档不写死具体值（随源码重建变化），以脚本输出为准；
- macOS 26+ 上 hdiutil attach/detach 会打印 deprecation warning（建议改用
  diskutil image attach / diskutil eject），但 hdiutil 仍可用；为了兼容 macOS 14+
  目标机型，脚本继续使用 hdiutil。验证脚本通过 diskutil info -plist 读取卷名。

历史构建示例（2026-11-08 20:38，0.2.0 时代；尺寸/校验和随源码重建变化，当前版本以脚本 `VERSION` 为准）：

```
dist/RDPServer-0.2.0.dmg  约 11 MB（历史示例；校验和随源码重建变化，不在此记录）
```

---
## 8. 验证（scripts/test-app-bundle.py）

行为：

1. 若 dist/RDPServer-0.2.2.dmg（以脚本 `DMG_PATH`/`VERSION` 为准）不存在则先运行 scripts/package-app-dmg.py --swift-build
   （--no-build 时直接失败）；
2. 把 DMG **只读**挂载到 /tmp/rdp-app-bundle-XXXX/mnt（hdiutil attach -nobrowse -readonly，
   若该镜像已被挂载则复用，不 eject 别人的挂载；自己上次残留的挂载会先 detach）；
3. 在挂载点/临时目录内执行全部检查；finally 中 detach + 清理临时目录；
4. 全部通过打印 OK 行与汇总；任一失败退出码非 0。--keep 保留临时目录便于排查。

检查项由脚本内的 `Checker` 动态计数，**不要在本文件写死通过项数**：当前共 17 个命名检查（含 `license files`），`--skip-service-check` 时为 16 passed + 1 skipped。末尾 `shared .runtime unchanged` 是额外的 OK/WARN 信息项，汇总行会把它计入 passed/warning；因此以脚本实际汇总为准，不要按本文档推算数字。

| 检查 | 断言 |
| --- | --- |
| dmg mounts | 只读挂载成功；卷名 RDP Server（diskutil info -plist） |
| dmg contents | 含 RDPServer.app（真实目录，非符号链接）；Applications -> /Applications 绝对符号链接 |
| bundle layout | Contents/MacOS/RDPServer、Contents/Helpers/{rdp-worker,rdpctl}、嵌套 agent 可执行存在且可执行；Contents/Frameworks/*.dylib 非空 |
| license files | Contents/Resources/Licenses/ 下 LICENSE、NOTICE、THIRD-PARTY-NOTICES.md 均存在；与**当前仓库根**同名文件逐字节一致（大小与 sha256；期望值运行时计算，不硬编码）；LICENSE 含 `Apache License`/`Version 2.0`/`END OF TERMS AND CONDITIONS`；NOTICE 含 `FreeRDP`/`OpenSSL`/`json-c`/`Go runtime`；THIRD-PARTY-NOTICES.md 含 `MIT`/`BSD-3-Clause`/`Apache-2.0` 及构建锁定的 FreeRDP 版本；输出各文件字节数与 sha256 前缀 |
| app Info.plist | id/name/executable/version(0.2.2)/build(1)/LSMinimumSystemVersion(14.0)/LSUIElement/NSHighResolutionCapable/CFBundleIconFile 全部符合契约 |
| nested agent Info.plist | id com.rdp-server.agent、executable rdp-agent、LSUIElement=true、有版本号 |
| codesign | codesign --verify --deep --strict 通过；外层 Signature=adhoc 且 Identifier=com.rdp-server.server；嵌套验证通过且 Identifier=com.rdp-server.agent |
| dylib relocation | 遍历 app 内全部 Mach-O：非系统依赖必须是 @rpath/<basename> 且存在于 Contents/Frameworks；dylib 的 install id 必须是 @rpath/...；不允许 /.deps/、仓库路径、/opt/homebrew、/Library/Developer 的 rpath；有非系统依赖的可执行必须有 @executable_path/../Frameworks |
| rdp-worker loads dylibs | rdp-worker -config <不存在> 退出非 0 且输出**不含** Library not loaded/dyld/image not found（证明 dyld 已解析全部 dylib） |
| rdpctl loads dylibs | rdpctl（无参数）退出 2 并打印 usage，无 dyld 错误 |
| rdp-worker starts with temp config | 用临时目录（0700）+ 临时 config/sam/key/cert（0600，cert 为占位内容、不建立连接）在 127.0.0.1 随机端口启动，最多 3 次重试端口冲突；必须出现 event=listening 与 event=agent_ipc_listening，然后 SIGTERM 停止（证明 cgo/FreeRDP 初始化在 bundle 内可用；不碰现有服务 3389/.runtime） |
| nested agent status | RDP_AGENT_NO_PERMISSION_REQUEST=1 rdp-agent status 退出 0 并输出 screen_recording=/accessibility=；**仅信息性**（TCC 状态按机器而异，不要求已授权） |
| relocatable copy (drag-install) | 把 app 复制到 <temp>/Applications/ 后，副本里的 rdp-worker 仍无 dyld 错误、嵌套 rdp-agent status 仍正常（证明 bundle 不依赖 DMG/仓库路径，等价 /Applications 安装位置） |
| RDPServer --status | --status --data-dir <temp> 退出 0，stdout 恰好一个 JSON 对象；不含 password/hash 字段；若含 data_directory 必须是传入的临时目录；worker.running 不得为 true；**不创建数据目录**（运行前不存在则运行后仍不存在） |
| RDPServer --self-test | --self-test --data-dir <temp> 退出 0，JSON ok=true（自检项数以 App 实际输出为准；本文不写死）；--status 不可用时跳过（SKIP） |
| RDPServer --self-test starts service | RDPSERVER_SELFTEST_START=1 --self-test --data-dir <temp> 退出 0、JSON ok=true 且**所有** checks 项 ok=true；必须包含 worker.started / worker.listening / worker.tcp_connect / agent.frames / cleanup.no_running_pids / cleanup.socket_removed（agent.frames 在无 TCC 机器上 detail 为 skipped，但仍须 ok=true）。证明打包后的 Worker 真能启动监听、嵌套 Agent 真能出帧并干净收尾。`--skip-service-check` 可跳过（例如无显示/TCC 的机器） |
| live data dir untouched | 运行前后 ~/Library/Application Support/RDPServer 的存在性/mtime/条目不变（FAIL 条件） |
| shared .runtime unchanged | 仓库 .runtime/ 前后不变；因为工作区可能被其它并行开发/测试进程写入，变化只作为 WARN，不归因于打包 app |

隔离措施：

- 所有 app 命令显式传 --data-dir <temp>，并把 HOME、TMPDIR 重定向到临时目录，
  清除继承的 RDPSERVER_DATA_DIR；
- 不启动 3389 上的服务、不读写现有 .runtime、不修改 bin/；
- 嵌套 agent 只跑 status，不申请 TCC、不连 Worker；
- worker 启动检查只用临时配置 + 随机 loopback 端口，次数受限（3 次）并 SIGTERM 结束；
- 临时目录前缀 rdp-app-bundle- 放在 /tmp 下（AF_UNIX sun_path 上限 104 字节，
  /private/var/folders/... 的 TMPDIR 会超长）。
- `RDPSERVER_SELFTEST_START=1` 那一项会在**临时数据目录**里短暂启动打包的 Worker（随机 loopback 端口）
  与嵌套 Agent 出帧，随后断言 cleanup.* 并退出；不连接 Windows 客户端、不改显示排列、不落盘；
  可用 `--skip-service-check` 跳过。

### 8.1 历史构建输出示例（2026-11-08 20:38，0.2.0 时代；项数/版本以脚本为准）

> 下面是历史输出，当时还没有 `license files` 检查项、版本为 0.2.0；当前输出会多一行 `OK license files (...)`，版本为 0.2.2，且项数以脚本实际运行为准。

```sh
$ make app-dmg
...
    /Users/<user>/.../dist/RDPServer-0.2.0.dmg
$ make test-app-bundle
OK   dmg mounts  (volume 'RDP Server' mounted at mnt)
OK   dmg contents  (RDPServer.app + Applications -> /Applications)
OK   bundle layout  (7 dylibs, helpers + nested agent present)
OK   app Info.plist  (com.rdp-server.server 0.2.0 (build 1), LSUIElement)
OK   nested agent Info.plist  (com.rdp-server.agent 0.2.0, LSUIElement)
OK   codesign  (adhoc, deep+strict verify passed; identifiers com.rdp-server.server / com.rdp-server.agent)
OK   dylib relocation  (11 Mach-O files, all non-system deps @rpath -> Contents/Frameworks)
OK   rdp-worker loads dylibs  (exit 1, config error (all dylibs loaded))
OK   rdpctl loads dylibs  (starts and prints usage (all dylibs loaded))
OK   rdp-worker starts with temp config  (listening on 127.0.0.1:20582 from a temp config, stopped with SIGTERM)
OK   nested agent status  (informational: screen_recording=granted accessibility=granted (TCC state is per machine))
OK   relocatable copy (drag-install)  (copied to Applications/: --status/--self-test ok (helpers source=bundle), nested agent TCC query identical (screen_recording=granted, accessibility=granted))
OK   RDPServer --status  (JSON ok=True state='disabled')
OK   RDPServer --self-test  (ok, 29 checks)
OK   RDPServer --self-test starts service  (worker started+listened, agent frames ok (sample pid/generation omitted), cleanup verified)
OK   live data dir untouched  (/Users/<user>/Library/Application Support/RDPServer untouched)
OK   shared .runtime unchanged  (.runtime untouched)
17 passed, 0 failed, 0 skipped, 0 warning(s)   # 历史：当时还没有 license files 项，供格式参考；当前项数以脚本为准
OK app bundle verified
# 注：在共享工作区重复运行时，若其它进程恰好在验证期间改动仓库 .runtime，
# shared .runtime unchanged 一项会变成 WARN（"not attributable"），其余仍全部 OK。
```

手工从挂载的 DMG 里执行（HOME/TMPDIR 重定向到临时目录、--data-dir 指向临时目录）：

```sh
$ RDPServer --version
RDPServer 0.2.0
$ RDPServer --status --data-dir <temp>
{"account":null,"address":"127.0.0.1:3389","agent":{"detail":null,"state":"waiting"},
 "allow_lan":false,"app_version":"0.2.0","configured":false,
 "data_directory":"/tmp/.../data","enabled":false,"error":null,"last_error":null,
 "listen_host":"127.0.0.1","logs_directory":"/tmp/.../data/logs","ok":true,
 "permissions":{"accessibility":true,"screen_recording":true},"port":3389,
 "principal":null,"state":"disabled","worker":{"pid":null,"running":false}}
$ RDPServer --self-test --data-dir <temp>      # stdout 一个 JSON；checks 项数以 App 实际输出为准
```

- `--status` 不创建数据目录、不启动 Worker（JSON 中 worker.running=false），
  只执行一次嵌套 rdp-agent status 取权限字段（无 TCC 提示）；
- `--self-test` 在传入的临时数据目录里做自检（项数以实际输出为准；helpers、paths、certificate、
  credentials、config、agent.permission_query、secrets），全部 ok；其中
  `agent.release_stuck_keys=supported`（ok=true）说明**打包的嵌套 agent 二进制确实带 SIGUSR1
  handler**：capability 探测在 agent 可执行文件里找到 `input_release_all` 日志标记；
  旧 Agent 无该标记时该项为 unsupported，菜单栏按钮会被禁用（避免 SIGUSR1 默认动作杀掉 Agent）。
  菜单栏 UI（高级 section）据此 gate「释放卡住按键」按钮：capability=false 时按钮禁用 +
  橙色说明；打包后的 RDPServer 二进制里可见 `release-stuck-keys button stays disabled` 文案，
  说明 20:38 的 DMG 已包含该 UI 能力门禁。
- 两项输出均通过"stdout 恰好一个 JSON 对象"的校验；逐项人类可读行在 stderr，不影响解析；
- 验证在**只读挂载的 DMG** 上完成，app 不写 ~/Library/Application Support/RDPServer、
  不写仓库 .runtime、不启动 3389 服务。
- **可移植性**：把 app 复制到 `<temp>/Applications/RDPServer.app` 后，`--status` / `--self-test`
  仍全部 ok，self-test 的 helpers `source=bundle` 且指向副本自身路径；输出不含仓库路径/
  `.deps`；嵌套 agent 的权限查询结果与 DMG 内完全一致（本机 TCC 按 bundle id/cdhash 识别，
  复制路径不影响授权）。
- `RDPSERVER_SELFTEST_START=1` 一项在只读 DMG 上验证了完整闭环：打包 Worker 启动并监听
  随机 loopback 端口、嵌套 RDPAgent.app 以自身 TCC 身份出帧、随后 worker/agent 全部停止、
  socket 清理、无残留 PID（`cleanup.*` checks 全 ok）。

---
## 9. 安装、首次启动、卸载与 TCC

### 9.1 安装

```sh
open dist/RDPServer-0.2.2.dmg        # 或在 Finder 双击（文件名以脚本 VERSION 为准）
# 把 RDPServer.app 拖到 Applications；或：
cp -R "/Volumes/RDP Server/RDPServer.app" /Applications/
hdiutil detach "/Volumes/RDP Server"  # 可省略
```

### 9.2 首次启动（ad-hoc、未公证）

产物是 **ad-hoc 签名、未公证**，从 DMG/网络下载的副本可能带 quarantine：

- Gatekeeper 阻止时：右键 RDPServer.app -> 打开（或系统设置 -> 隐私与安全性 -> 仍要打开）；
- 或清除隔离属性：xattr -dr com.apple.quarantine /Applications/RDPServer.app；
- 不要关闭 SIP、不要改 TCC 数据库（项目硬边界）。

启动后是菜单栏 app（LSUIElement，无 Dock 图标）。按设计**启动本身不启动服务、
不主动申请 TCC**；用户点击启用后 app 才启动 Contents/Helpers/rdp-worker 与嵌套 Agent
（具体行为见 app-ui/app-core 设计文档）。

### 9.3 卸载

```sh
# 1) 在菜单栏 app 中先停止服务并退出
# 2) 删除 app
rm -rf /Applications/RDPServer.app
# 3) 数据目录（用户数据/配置/凭据/证书）需手工删除：
rm -rf ~/Library/Application\ Support/RDPServer
```

打包脚本/验证脚本**不会**删除真实数据目录。DMG 不包含卸载器。

### 9.4 TCC（权限）

- 屏幕录制 / 辅助功能属于**嵌套 RDPAgent.app**（com.rdp-server.agent），
  在系统设置 -> 隐私与安全性中授权；每次重新打包 cdhash 变化后可能需要重新授权；
- 文件剪贴板读取桌面/文稿/下载等受保护目录时，需要给该 app **完全磁盘访问**；
- 若 app 以自身身份（com.rdp-server.server）启动 helper 并被系统记录权限，可能需要
  对 app 本身授权——**待真机复验**（当前未验证）；
- 验证脚本不要求 TCC 已授权（只读 status 输出，见 §8）。

---

## 10. 已知限制与 TODO

1. **未公证/无 Developer ID**：Gatekeeper 提示、TCC 授权不稳定；发布前需 Developer ID +
   notarytool + hardened runtime/entitlements（打包脚本需增加 --sign-identity 参数）。
2. **每次重建 cdhash 变化 -> 可能需要重新授权 TCC**（ad-hoc 固有限制）。
3. **app CLI 已落地并验证**（--status/--self-test，自检项数以实际输出为准）；app-core/app-ui 仍在
   迭代菜单栏 UI，若新增 helper 或改变行为需复跑 `make app-dmg && make test-app-bundle`。
4. **App 图标**：已随包 `Contents/Resources/AppIcon.icns`（自绘寻呼机图标，`scripts/generate-app-icon.py` 生成）并设置 `CFBundleIconFile=AppIcon`；调整图标需重新运行生成脚本或更新 `native/macos/Resources/AppIcon.icns` 后重新打包。菜单栏状态字形仍为系统 emoji 📟（运行期渲染，不随包分发位图）。
5. **无自动启动/开机自启/升级/卸载**：没有 LaunchDaemon/登录项，没有版本迁移逻辑；
   卸载靠手工删除（§9.3）。
6. **仅 arm64（Apple Silicon）**：与项目硬件边界一致；未做 universal2 / x86_64。
7. **DMG 用 HFS+**，无自定义外观；macOS 26+ 的 hdiutil deprecation warning（功能正常）。
8. 依赖仓库 .deps/install 构建：DMG 本身**不依赖**仓库/Homebrew，但**构建**需要它们。
9. app 若改变 helper 路径/环境变量/CLI，需要同步更新
   scripts/package-app-dmg.py、scripts/test-app-bundle.py 与本文档。

---

## 11. 故障排查

| 症状 | 原因/处理 |
| --- | --- |
| hdiutil attach 报「资源忙」 | 镜像已被挂载：hdiutil info 找到挂载点后 hdiutil detach <mountpoint>；test-app-bundle.py 会自动复用已有挂载/清理自己的残留挂载。 |
| 启动 app 报 Library not loaded: @rpath/lib... | dylib 没进 Frameworks 或 helper 缺 @executable_path/../Frameworks rpath：otool -L / otool -l 检查，重跑 make app-dmg；make test-app-bundle 的 dylib relocation 项会报具体文件。 |
| codesign --verify 失败 | 改过 Mach-O 没重签，或顺序错误：必须嵌套先签、外层最后且不加 --deep；重跑打包脚本。 |
| 嵌套 agent 权限「看起来」丢了 | ad-hoc 重打包 cdhash 变化，去系统设置重新授权；用 rdp-agent status（app 内路径）确认；不要改 TCC 数据库。 |
| --status/--self-test 卡住/无 JSON | app 侧未实现 headless flag（会启动 GUI）；实现后应打印 JSON 并退出。验证脚本有 60s/180s 超时。 |
| 验证脚本连到现有服务 | 不应发生：脚本用临时 --data-dir + 随机端口 + HOME/TMPDIR 重定向；若出现，检查 app 是否忽略 --data-dir。 |
| .runtime 被改动 | 共享工作区里其它并行进程也可能写；验证脚本只 WARN 不归因。真正要担心的是 app 数据目录（脚本 FAIL 项）。 |

---

## 12. 维护

- 布局/依赖/签名变化时更新本文档与脚本注释；
- 版本号：改 VERSION/BUILD_NUMBER（scripts/package-app-dmg.py）时同步 DMG 文件名、
  验证脚本常量（EXPECTED_VERSION）与本文档；当前 `VERSION=0.2.2`；
- 许可证：`license files`（`LICENSE`/`NOTICE`/`THIRD-PARTY-NOTICES.md`）由打包脚本自动复制并由验证脚本检查；新增/修改第三方依赖或许可证文本时同步 `THIRD-PARTY-NOTICES.md`、`NOTICE` 与 DEPENDENCIES §8，再跑 `make app-dmg && make test-app-bundle`；
- 新增 helper 时同步 HELPER_NAMES、验证脚本清单与 app 侧查找逻辑。

