# 第三方组件与许可证声明（THIRD-PARTY-NOTICES）

> 适用产物：发布用 DMG / App（`make app-dmg` 生成 `dist/RDPServer-0.2.4.dmg` 与 `dist/RDPServer.app`）。
> 打包脚本会把根 `LICENSE` / `NOTICE` / 本文件复制到 `Contents/Resources/Licenses/`（见 §4 第 4 条）。
> `dist/` 是本地构建产物（已 gitignore、不入库），发布前请重新执行 `make app-dmg`，确保包内实际携带这些文件。
> 本文件与根目录 [LICENSE](LICENSE)（Apache License 2.0 全文）、[NOTICE](NOTICE) 配套使用。
>
> 核查方式：只读检查 `scripts/package-app-dmg.py`、`native/macos/Package.swift`、
> `scripts/build-freerdp.sh`、`docs/DESIGN-2026-11-08-app-packaging.md`、`.deps/install/lib`、
> `dist/RDPServer.app/Contents/Frameworks` 与已构建二进制的 `otool -L` / `go version -m` 输出。
>
> 结论：当前 DMG **只分发 7 个第三方动态库**——FreeRDP/WinPR 4 个、OpenSSL 2 个、json-c 1 个；
> 另有 Go 运行时**静态链接**进 `rdp-worker` / `rdpctl`。其余依赖由 macOS 提供，不随包分发。
> 打包时还会把根 `LICENSE` / `NOTICE` / 本文件复制到 `Contents/Resources/Licenses/`（见 §4 第 4 条）。
>
> 本文不是法律意见；正式发布前如需法律审查，请咨询专业人士。

## 1. 汇总表

### 1.1 随 DMG 分发的第三方组件

| 组件 | 版本 | 许可证 | 分发形式 | 随包文件 / 位置 | 义务（保留版权声明 / NOTICE / 源码提供？） |
| --- | --- | --- | --- | --- | --- |
| FreeRDP（含 WinPR） | 3.32.2 | Apache-2.0 | 动态链接 | `Contents/Frameworks/` 下 `libfreerdp3.3.dylib`、`libfreerdp-server3.3.dylib`、`libfreerdp-client3.3.dylib`、`libwinpr3.3.dylib` | 随附 Apache-2.0 副本（根 [LICENSE](LICENSE)）；保留版权/归属声明；如上游分发 NOTICE 则随附（见 §3.4）；**无源码提供义务**；若修改源码需显著标注（本项目未修改） |
| OpenSSL | 3.5.9（Homebrew `openssl@3`，仓库未固定版本） | Apache-2.0 | 动态链接 | `Contents/Frameworks/libssl.3.dylib`、`libcrypto.3.dylib` | 同上：随附许可证副本并保留归属声明；**无源码提供义务** |
| json-c | 0.19（Homebrew，仓库未固定版本；soname `libjson-c.5`） | MIT | 动态链接 | `Contents/Frameworks/libjson-c.5.dylib` | 在副本/实质部分中保留版权声明与 MIT 许可全文（见 §3.2）；**无源码提供义务** |
| Go 运行时 | 1.27.3（`go.mod` 要求 `go 1.27`） | BSD-3-Clause | 静态链接（编译进 `rdp-worker`、`rdpctl`） | 无独立文件 | 二进制分发需在文档/随附材料中复现版权声明、条件与免责声明（见 §3.3）；不得以 Google LLC 或贡献者名义为产品背书；**无源码提供义务** |

### 1.2 存在于构建树但不随包分发 / 未链接的组件

| 组件 | 版本 | 许可证 | 分发形式 | 说明 |
| --- | --- | --- | --- | --- |
| WinPR tools（`libwinpr-tools3.3.dylib`） | 3.32.2 | Apache-2.0 | 不随包 | 存在于 `.deps/install/lib`，但未链接进 helper，也未复制到 `Contents/Frameworks`（该目录只有上述 7 个 dylib） |
| zlib（`/usr/lib/libz.1.dylib`） | macOS 系统版本（`otool` 显示 current version 1.2.12） | Apple 系统许可 | 不随包 | `libfreerdp3.3.dylib` 动态依赖系统 zlib；打包脚本将 `/usr/lib/` 视为系统路径，不复制 |
| Swift 运行库与 Apple 框架 | 随 macOS | Apple 系统许可 | 不随包 | `RDPServer` / `rdp-agent` 链接 `/usr/lib/swift/*`、AppKit、ScreenCaptureKit 等系统库 |
| FreeRDP Android cpufeatures | 上游 3.32.2 归档内（AOSP 2010 源码头 / 2016 NOTICE） | **BSD-3-Clause**（源码头；同目录 `NOTICE` 为 Apache-2.0 样板声明，以源码头为准） | 未编译、未分发（仅随源码归档存档） | `winpr/libwinpr/sysinfo/CMakeLists.txt` 只在 `if(ANDROID)` 时 `add_subdirectory(cpufeatures)`；macOS 构建不编译、不链接，DMG 无对应代码。见 §3.4 |
| FFmpeg / OpenH264 / opus / CUPS / PCSC / KRB5 / PKCS11 / AAD | — | — | 不随包 | `scripts/build-freerdp.sh` 显式 `OFF`；DMG 内无对应库 |

## 2. 逐组件核实

### 2.1 FreeRDP / WinPR 3.32.2

- 上游：<https://github.com/FreeRDP/FreeRDP>，release `3.32.2`；下载归档 `.deps/downloads/freerdp-3.32.2.tar.gz`，
  SHA-256 `e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c`（与 `scripts/build-freerdp.sh` 固定值一致）。
- 许可证：上游归档根 `LICENSE` 为 Apache License 2.0 全文；本仓库根 [LICENSE](LICENSE) 与其
  **逐字节一致**（`cmp` 无差异，11,358 字节，SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`），可作为分发时的许可证副本。
- 构建方式：`scripts/build-freerdp.sh` 用 CMake 构建（`WITH_SERVER=ON`、`WITH_CLIENT_COMMON=ON`、
  `WITH_CLIENT=OFF`、`WITH_CHANNELS=ON`、`WITH_INTERNAL_MD4=ON`、`WITH_INTERNAL_RC4=ON`、
  `WINPR_HAVE_PIPE2=OFF`），**没有对 FreeRDP 源码打补丁**，只改构建选项。
- 分发形态：`rdp-worker` / `rdpctl` 通过 cgo 动态链接 4 个 dylib；`otool -L` 显示
  current version 为 `3.32.2`，打包脚本把它们重定位到 `@rpath` 并放入 `Contents/Frameworks`。
- 上游 NOTICE：3.32.2 归档**没有顶层 NOTICE**；唯一的 NOTICE 在
  `winpr/libwinpr/sysinfo/cpufeatures/NOTICE`（Android AOSP）。注意该目录**源码头是 BSD-3-Clause**
  （Copyright (C) 2010 The Android Open Source Project），而 NOTICE 文件正文是 Apache-2.0 样板声明
  （上游自身不一致，以源码头为准）。该目录只在 `ANDROID` 构建时加入，macOS 构建**不编译、不链接、**
  **不分发**；其 NOTICE 原文仅作上游归属存档于 §3.4。
- 内嵌第三方代码（已静态编译进 `libwinpr3.3.dylib`）：
  - MD4：`winpr/libwinpr/crypto/md4.c`，Alexander Peslyak（Solar Designer）2001 年实现，
    声明为 public domain，并附 BSD 式许可兜底；
  - RC4：`winpr/libwinpr/crypto/rc4.c`，Copyright 2023 Armin Novak / Thincast Technologies GmbH，
    Apache-2.0（与 FreeRDP 主许可证一致）。
  两者均通过 `-DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON` 编入，目的是避免运行期依赖
  OpenSSL 3 的 legacy provider 模块。

### 2.2 OpenSSL 3.5.9

- 来源：构建机 Homebrew `openssl@3`（`brew list --versions openssl@3` → `openssl@3 3.5.9`）；
  `scripts/build-freerdp.sh` 通过 `OPENSSL_ROOT_DIR=$(brew --prefix openssl@3)` 使用它。
- 许可证：`$(brew --prefix openssl@3)/LICENSE.txt` 为 Apache License 2.0；版权归
  The OpenSSL Project Authors。根 [LICENSE](LICENSE) 提供同一许可证全文。
- 分发形态：`Contents/Frameworks/libssl.3.dylib`、`libcrypto.3.dylib`；`libwinpr3.3.dylib`
  与 `libfreerdp3.3.dylib` 通过 `@rpath` 引用它们。打包后的 `libcrypto.3.dylib` 内含
  `OpenSSL 3.5.9 29 Sep 2026` 版本串，与 Homebrew 记录一致。
- 注意：仓库脚本**没有固定 OpenSSL 版本**（依赖构建机 Homebrew），重建时可能升级。
  升级后应重新核对 `LICENSE.txt` 与版本号并更新本表。系统 `/usr/bin/openssl` 是 LibreSSL，
  与本包无关，不随包分发。

### 2.3 json-c 0.19

- 来源：构建机 Homebrew `json-c`（`brew list --versions json-c` → `json-c 0.19`）；
  由 WinPR 的 JSON 后端探测自动链接（`libwinpr3.3.dylib` 的 `otool -L` 可见 `libjson-c.5`）。
- 许可证：`$(brew --prefix json-c)/COPYING` 为 MIT；包含 Eric Haszlakiewicz（2009-2012）与
  Metaparadigm Pte Ltd（2004, 2005）两段版权。全文见 §3.2。
- 分发形态：`Contents/Frameworks/libjson-c.5.dylib`（soname `libjson-c.5`，`otool` 显示
  current version 5.5.0；二进制内含 `0.19` 版本串）。
- 仓库同样**未固定 json-c 版本**，升级时需复核许可证与版本。

### 2.4 Go 运行时 1.27.3（静态链接）

- 构建：`go version` → `go1.27.3 darwin/arm64`；`go version -m dist/RDPServer.app/Contents/Helpers/rdp-worker`
  显示该 helper 使用 `go1.27.3` 构建、`CGO_ENABLED=1`。`go.mod` 声明 `go 1.27`，无第三方 Go 模块。
- 分发形态：Go 运行时与标准库**静态链接**进 `rdp-worker` 和 `rdpctl`，没有独立的 Go dylib。
- 许可证：BSD-3-Clause（Copyright 2009 The Go Authors），全文见 §3.3。
- 注意：Go 发行版另含 `PATENTS` 文件（专利授权声明），不属于版权许可文本；
  本文件按 Go 发行版 `LICENSE` 原文收录主许可文本，如需完整复现 Go 的授权材料可一并附上 `PATENTS`。

### 2.5 系统组件（不随包）

- `RDPServer` 与嵌套 `rdp-agent` 只链接 Apple 系统框架与 `/usr/lib/swift/*`，这些由目标 macOS 提供，
  不进入 DMG；其许可由 Apple 系统软件许可覆盖。
- `libfreerdp3.3.dylib` 依赖 `/usr/lib/libz.1.dylib`，属于 macOS 系统库，打包脚本按
  `/usr/lib/` 前缀跳过，不复制。

## 3. 许可证与归属声明全文

### 3.1 Apache License 2.0

本项目自身、FreeRDP/WinPR 与 OpenSSL 均使用 Apache License 2.0。全文见仓库根 [LICENSE](LICENSE)
（包含 `END OF TERMS AND CONDITIONS` 与附录样板）。该文件与 FreeRDP 3.32.2 归档内 Apache-2.0
`LICENSE` **逐字节一致**（`cmp` 无差异，11,358 字节，SHA-256
`cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`）；离线环境无法核对
apache.org 官方文件，故此处只声明与 FreeRDP 归档的字节一致性。分发时请随附该文件。

### 3.2 MIT License（json-c）

```text
Copyright (c) 2009-2012 Eric Haszlakiewicz

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

----------------------------------------------------------------

Copyright (c) 2004, 2005 Metaparadigm Pte Ltd

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### 3.3 BSD 3-Clause License（Go）

```text
Copyright 2009 The Go Authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 3.4 FreeRDP 上游 NOTICE（Android cpufeatures：未编译 / 未分发，仅存档）

来源：FreeRDP 3.32.2 归档 `winpr/libwinpr/sysinfo/cpufeatures/NOTICE`。该目录的**源码头文件
（`cpu-features.c` / `cpu-features.h`）采用 BSD-3-Clause**（Copyright (C) 2010 The Android Open
Source Project），而随附 `NOTICE` 正文是 Apache-2.0 样板声明——上游自身不一致，以源码头为准。
该目录只在 `if(ANDROID)` 时加入构建，macOS 构建不编译、不链接，DMG 不含其代码。以下原文照录，
仅作上游归属存档，不表示本项目分发该组件。

```text
Copyright (C) 2016 The Android Open Source Project

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## 4. 合规结论与发布前检查

1. **Apache-2.0（FreeRDP/WinPR、OpenSSL）**：随附根 [LICENSE](LICENSE) 即满足"提供许可证副本"；
   [NOTICE](NOTICE) 与本文件保留归属声明；上游唯一的 NOTICE 属 Android-only cpufeatures
   （未编译、未分发，仅存档于 §3.4），macOS 产物不涉及该组件。Apache-2.0 **不要求**
   开源本项目，也不要求提供源码；但若修改了第三方源码，必须显著标注修改。本项目未修改 FreeRDP 源码，
   仅通过 CMake 选项改变构建配置。
2. **MIT（json-c）**：必须在副本或实质部分中保留版权声明与许可声明；§3.2 已收录全文，
   本文件需随发行物一起提供。
3. **BSD-3-Clause（Go）**：二进制分发需在文档/随附材料中复现版权声明、条件与免责声明；
   §3.3 已收录全文。
4. **打包已把许可证复制进 bundle（2026-11-09 起）**：`scripts/package-app-dmg.py` 的
   `copy_license_files()`（约 :195，在 `assemble_app()` 内、`codesign` 之前调用）会把根
   `LICENSE`、`NOTICE`、`THIRD-PARTY-NOTICES.md` 复制到 `Contents/Resources/Licenses/`；
   源文件缺失或为空时构建直接失败（`missing license file ...` / `empty license file ...`），
   不会产出不合规包。`scripts/test-app-bundle.py` 的 `check_licenses()` 校验该目录存在、
   三份文件非空且含预期标记。
   **注意**：0.2.2 及更早的 `dist/RDPServer-0.2.2.dmg` 是加入该逻辑**之前**的构建；
   0.2.3 起每次 `make app-dmg` 都会把许可证复制进 bundle。若本机在服务真实 RDP 会话，
   不要随意重建/覆盖部署产物。验证命令见 §5。
5. **版本未固定风险**：OpenSSL 与 json-c 来自构建机 Homebrew，仓库未固定版本；升级后需重新核对
   许可证与版本并更新本表。FreeRDP 版本与归档 SHA-256 已固定，可直接复现。
6. **未发现 copyleft 组件**：当前 DMG 内 7 个 dylib 均为 Apache-2.0 或 MIT；对 FreeRDP 的
   `channels/`、`libfreerdp/`、`winpr/` 源码检索未发现 GPL/LGPL/MPL 许可头。若将来启用
   FFmpeg/OpenH264 等可选路径，必须重新评估分发义务。

## 5. 复现核查命令

```sh
# 组件版本（构建机）
brew list --versions openssl@3 json-c
go version
shasum -a 256 .deps/downloads/freerdp-3.32.2.tar.gz

# 实际随包的 7 个 dylib
find dist/RDPServer.app/Contents/Frameworks -maxdepth 1 -name '*.dylib' -print | sort

# 依赖与链接关系（应只看到 @rpath 与系统库）
for f in dist/RDPServer.app/Contents/Frameworks/*.dylib; do
  echo "== $f"; otool -L "$f"
done
otool -L dist/RDPServer.app/Contents/Helpers/rdp-worker

# 确认 libwinpr-tools 未随包
ls dist/RDPServer.app/Contents/Frameworks | grep -i winpr-tools || echo "not bundled"

# 许可证来源
head -5 .deps/freerdp-3.32.2/LICENSE
head -5 "$(brew --prefix openssl@3)/LICENSE.txt"
cat "$(brew --prefix json-c)/COPYING"
cmp LICENSE .deps/freerdp-3.32.2/LICENSE && echo "LICENSE byte-identical to FreeRDP archive"

# 打包是否把三份许可证复制进 bundle（实现 + 现有包状态）
grep -n "def copy_license_files" scripts/package-app-dmg.py
ls -l dist/RDPServer.app/Contents/Resources/Licenses/ 2>/dev/null \
  || echo "当前 dist 是加入 license 复制逻辑之前的构建；重建后才会出现 Licenses/"
# 重建后的 bundle 校验（只读挂载 DMG；含 license files 项）
python3 scripts/test-app-bundle.py
```
