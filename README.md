# oc-centos7 — 全静态 musl 构建管线

让 opencode（含 TUI）跑在 CentOS 7 上。上游仓库（bun/opencode）不改源码；
所有改动在此仓库：`patches/` 幂等应用，`src/dl-symtab.c` 提供 dlopen/dlsym 拦截。

## 快速开始

```sh
scripts/build-opentui.sh   # zig 交叉编译 libopentui.a + dl-symtab.o（宿主）
scripts/build-bun.sh       # 容器内构建静态 musl bun（增量 ~2h 冷编译）
scripts/build-opencode.sh  # alpine 容器打包 standalone opencode
scripts/verify-centos7.sh  # c7 容器全项验证（bun/dlopen/headless/TUI）
```

详见 [PLAN.md](PLAN.md)（机制、排除路线、风险）。
