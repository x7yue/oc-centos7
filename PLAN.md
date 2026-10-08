# CentOS 7 适配构建方案

## 边界

目标是将固定版本的 Bun 和 OpenCode v2 (`@opencode/cli`) 构建为 CentOS 7 可运行的 x86_64 musl 可执行文件，并保持上游默认功能与 Web UI。此仓库不维护应用功能分支；上游源码只在 CI checkout 内临时打补丁。发行命令与内置 CLI 名称均为 `opencode2`。

## 构建链

1. `scripts/sync-upstream.sh` 将 Bun、OpenCode、OpenTUI 固定到 `versions.json` 的 tag，写入精确提交 SHA，并在源码树上预检补丁。
2. `scripts/build-opentui.sh` 用 OpenTUI v0.5 的 `packages/native/build.zig`、Zig 0.16 和 `-Dlibrary-target=x86_64-linux-musl` 构建 `libopentui.a`。静态模式另外以 musl sysroot 的 C++ 标准库编译 Yoga，输出 `libyoga_cxx.a`。`dl-symtab.o` 和 `undefined.rsp` 同步生成。
3. `scripts/build-bun.sh` 基于 Bun v1.4.2 构建静态 musl 运行时，将 OpenTUI/Yoga 与 FFI 拦截对象预链接，保留运行时 `dlsym` 所需 `.symtab`，写入不可变构建身份。
4. `scripts/build-opencode.sh` 用上游 Bun 安装依赖并构建 Web UI，再用上述静态 Bun 执行 v2 原生 `--target=opencode-linux-x64-musl` 构建。补丁只允许复用已构建的 Web UI archive，并设置 `OPENCODE_CLI_NAME=opencode2`。
5. `.github/workflows/build.yml` 上传产物后，在全新 CentOS 7 job 内验证；验证成功才创建 GitHub Release。

## 为什么需要补丁

完全静态的 musl 进程没有常规动态加载器。OpenTUI 通过 Bun FFI 请求原生符号，直接加载 `.so` 会失败。`patches/bun-flags-static.patch` 设置静态链接；`patches/bun-flags-dlopen.patch` 将 OpenTUI/Yoga 归档和 [`src/dl-symtab.c`](src/dl-symtab.c) 链入 Bun，并保留 `.symtab`。`patches/opentui-static-lib.patch` 让上游 OpenTUI 的单目标构建支持静态归档。OpenCode v2 已有目标选择参数，不再需要旧的 target-list 补丁。

预链接方案仅覆盖被链接的符号，不会把静态 musl 变成通用动态加载器。其他 `.node`/`.so` 依赖仍需在 CentOS 7 上验证，尤其是文件监听与平台专用功能。真实模型请求还需要单独提供上游支持的凭据；没有凭据的 CI 只验证无需外部服务的运行路径。

## 验证和发布原则

- CI 必须验证补丁上下文、OpenTUI 导出、静态 Bun 的符号表、构建身份和 `opencode2 --version`。
- CentOS 7 job 必须验证 FFI 符号解析、TUI 持续运行、CLI 帮助及 `serve` 返回 HTML；非预期退出、超时之外的 TUI 状态或 HTTP 失败都阻断发布。
- `skip_verify` 只上传暂存构建产物；Release 必须依赖成功的独立验证 job。
- GitHub Release 不覆盖已有 tag。缓存键绑定提交、补丁与构建身份；缓存命中仍执行产物有效性检查。

旧版本关于 v1 `packages/opencode`、OpenTUI `packages/core/src/zig`、跳过 Web UI、`bun` canary 的路径与结论不适用于此链路。具体上游依据见 [`UPSTREAM-RESEARCH.md`](UPSTREAM-RESEARCH.md)。
