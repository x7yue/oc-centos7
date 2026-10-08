# OpenCode v2 / Bun for CentOS 7

此仓库只负责把上游 Bun、OpenTUI 和 `@opencode/cli` 构建成可在 CentOS 7 上运行的 x86_64 musl 产物。应用功能、依赖版本和 CLI 行为以对应上游 tag 为准；发行命令是 `opencode2`。正式构建、运行验证与发布全部在 GitHub Actions 上完成，本地无需编译。

## 当前版本

| 上游 | 固定 tag | 用途 |
| --- | --- | --- |
| Bun | `bun-v1.4.2` | 编译静态 musl 运行时及 OpenCode CLI |
| OpenCode | `v2.0.24` | `@opencode/cli`，`opencode2` 命令 |
| OpenTUI | `v0.5.14` | 匹配 OpenCode v2 依赖的原生 TUI ABI |

具体 pin 在 [`versions.json`](versions.json)。升级依据、上游源码链接与兼容性边界见 [`UPSTREAM-RESEARCH.md`](UPSTREAM-RESEARCH.md)，构建机制见 [`PLAN.md`](PLAN.md)。

## GitHub Actions

PR 会自动运行 `build` 工作流并通过 CentOS 7 验证；PR 构建不会发布。正式发行在 Actions 中手动运行同一工作流，默认读取 `versions.json`，也可以覆盖三个 ref 或发布 tag。

1. 克隆固定上游提交并预检所有补丁；任何上下文漂移立即失败。
2. 使用 Buildx 缓存构建工具链镜像，依次构建 OpenTUI 静态库、静态 Bun、包含 Web UI 的 OpenCode v2 CLI。
3. 上传 `opencode2-linux-x64-musl`、`bun-linux-x64-musl-static`、校验和与版本身份文件。
4. 在独立的 CentOS 7 job 中核对校验和、Bun/FFI、`opencode2` CLI、TUI 存活以及 Web UI HTTP 响应。**仅手动发行且验证成功才创建 Release**。

`skip_verify=true` 只用于取得构建产物：验证 job 和 Release 都会跳过。Release tag 默认由 OpenCode ref、Bun/OpenTUI 提交和补丁哈希组成；同名 tag 已存在时工作流会提前失败。正式发行要求仓库启用 immutable releases，先将全部附件上传到草稿，再发布并核对 tag 指向和不可变状态。

验证分支可使用 `skip_release=true`：完整执行 CentOS 7 验证，但不创建 Release。

缓存按解析后的提交、补丁/构建身份和 Zig 版本隔离；脚本还会检查产物本身，避免仅凭缓存命中跳过构建。构建日志作为 `build-logs` 上传，CentOS 7 验证日志作为 `verify-logs` 上传，失败时仍会保留已产生的日志。

## 发行物

`opencode2-linux-x64-musl` 是上游 `packages/cli/dist/cli-linux-x64-musl/bin/opencode` 的重命名副本，CLI 内置名称也设为 `opencode2`。这是可直接运行的命令，不需要 npm 或本机 Bun。独立提供 Bun 运行时便于调试和其他静态 musl 使用场景。两者的 SHA-256 与精确上游提交记录在 Release 附件中。

静态 musl 运行时不能正常加载动态 `.so`/`.node`：仓库把 OpenTUI 原生实现预链接到 Bun，再用 [`src/dl-symtab.c`](src/dl-symtab.c) 解析 FFI 符号。OpenCode v2 的其他原生模块是否都能覆盖目标工作流，仍以 CentOS 7 job 和实际使用场景为准；无模型凭据的 CI 不会发起真实 LLM 请求。

## 下一次升级

1. 在 `versions.json` 固定新的上游 tag。保持 OpenTUI tag 与 OpenCode 依赖版本一致，并查看上游所需 Zig/Bun 版本。
2. 对照上游源码调整 `patches/`、Dockerfile 和脚本路径；先让 Actions 的 sync/补丁预检通过。
3. 运行默认工作流，查看三个构建日志与 `verify-logs`；只有 CentOS 7 job 全绿才发布。不要在已发布 tag 上替换附件。

`scripts/sync-upstream.sh` 会强制清理其管理的上游 checkout；它只适合全新 CI 工作目录，不应拿已有手工修改的本地上游目录试运行。
