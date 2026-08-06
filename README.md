# oc-centos7 — 全静态 musl 构建管线

让 opencode（含 TUI）跑在 CentOS 7 上。上游仓库（bun/opencode/opentui）不改源码；
所有改动在此仓库：`patches/` 幂等应用，`src/dl-symtab.c` 提供 dlopen/dlsym 拦截。

## 本地构建

```sh
scripts/sync-upstream.sh    # 同步三个上游到 versions.json 的 pin，并预检补丁
scripts/build-images.sh     # 构建 bun-musl-build-env / alpine-oc-build 镜像
scripts/build-opentui.sh    # zig 交叉编译 libopentui.a + libyoga_cxx.a + dl-symtab.o
scripts/build-bun.sh        # 容器内构建静态 musl bun（增量，冷编译约 1-2h，WSL 内存小请勿加并发）
scripts/build-opencode.sh   # alpine 容器打包 standalone opencode
scripts/verify-centos7.sh   # c7 容器全项验证（bun/dlopen/headless/TUI）
```

产物：
- `opencode/packages/opencode/dist/opencode-linux-x64-musl/bin/opencode` — 主产物
- `bun/build/release-musl-static/bun` — 静态 bun（87MB，`.symtab` 保留供 dlsym）
- `output/opentui/` — libopentui.a / libyoga_cxx.a / dl-symtab.o / undefined.rsp

注意：本地已有的容器（`bun-build` / `oc-build`）不会自动获得新的缓存挂载参数，
需要 `docker rm -f bun-build oc-build` 后重建才生效（CI 每次全新环境，无此问题）。

## GitHub Actions（公开仓库）

`.github/workflows/build.yml` — `workflow_dispatch` 手动触发（也可以复用来发定时）：

1. **build**（ubuntu-latest）：构建镜像 → sync 上游 + 补丁预检 → opentui → bun → opencode
   → 打包（opencode + bun + libopentui.so + sha256sums + versions.txt）→ upload artifact
2. **verify**（可选跳过）：centos:7 容器全项验证
3. **release**：打 tag `oc-<日期>-<bun 短 sha>` 并发 GitHub Release（含全部产物）

输入：
- `bun_ref` / `opencode_ref` / `opentui_ref` — 覆盖 `versions.json` 的 pin
- `skip_verify` — 跳过验证直接发布
- `tag` — 自定义 release tag

缓存（actions/cache）：bun 增量构建目录、zig、cargo registry、opencode node_modules。
**补丁预检失败 = workflow 直接失败**，不会产出坏产物。

## 上游升级指南

补丁基于上游特定 commit 的上下文，升级时可能漂移：

1. 修改 `versions.json` 里的 `ref`（bun 是 canary commit —— release tag 仍是旧构建系统，
   见 versions.json 的 note；opencode / opentui 用 release tag）。
2. 本地跑 `scripts/sync-upstream.sh`，看补丁预检：
   - 全部 OK → 本地完整构建 + verify 一遍，提交。
   - 失败 → 在对应 repo 里：
     ```sh
     cd bun && git apply --3way ../patches/bun-flags-dlopen.patch   # 能合则合
     # 手动调整后重新生成补丁：
     git diff > ../patches/bun-flags-dlopen.patch
     ```
     注意 `apply_patch` 以 marker 判断幂等（见 scripts/env.sh），重打补丁后
     用 `git apply --reverse --check` 或直接在干净 checkout 上验证。
3. 提交（含补丁、versions.json、PLAN.md 变更）。

## 关键机制速览

- 静态 musl 无动态加载器 → `--whole-archive` 把 libopentui.a + libyoga_cxx.a 链入 exe；
  `undefined.rsp`（`--undefined=` 列表）保证 `--gc-sections` 不清除这些符号；
  strip 用 `--strip-debug` 保留 `.symtab`；`dl-symtab.c` 的 strong dlopen/dlsym 从
  自身 `.symtab` 解析符号（FFI 的 `dlsym` 调用）。
- yoga C++ 用系统 clang++ + musl sysroot libstdc++ 编译（zig cc 只有 libc++，
  其运行时不在 bun 链接行上）。
- opencode 构建带 `--skip-embed-web-ui`：vite/rollup 的 `.node` 原生模块在静态
  musl 下无法加载（无加载器），跳过 web UI 嵌入不影响 TUI。

详见 [PLAN.md](PLAN.md)（机制、排除路线、风险）。
