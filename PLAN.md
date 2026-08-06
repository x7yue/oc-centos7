# CentOS 7 上运行 opencode：全静态 musl 方案

## 目标

在 CentOS 7（glibc 2.17，无 modern 工具链）上运行 opencode 的完整功能：
TUI（opentui）、headless LLM 运行、bun 运行时。产物为**单文件、全静态**可执行程序。

## 已排除的路线（实证结论）

| 路线 | 结论 |
|---|---|
| A. opentui JS/软件渲染降级 | 不存在。0.4.5/0.5.1 无任何纯 JS 渲染路径；`@opentui/core-linux-x64` 在宿主机全局删除后，宿主 bun 同样报致命错。`targetLibError` 只会 throw。 |
| B. CentOS 7 原生编译 bun | 硬件墙：LLVM 21.1.8 预编译包需要 GLIBC_2.38 + CXXABI_1.3.13（objdump 实证），官方无 x86_64-linux 包；bootstrap.sh 仅支持 apt。gcc 4.8.5、rustup nightly 均已实测可装，但 LLVM 是死路。 |
| C. glibc 2.17 sysroot 动态编译 | 可行但只解决 glibc 主机；musl 主机（alpine 等）仍有 TUI 问题；且分发物依赖 `LD_LIBRARY_PATH` 与符号兼容面。备选方案。 |
| D. **全静态 musl + 符号表 dlopen（本方案）** | 单一静态文件，所有 x86_64 Linux 主机可用。 |

## 核心事实（均已实证）

1. musl 1.2.x 的 `libc.a` 中 dl* 族只有 **weak stub**（`src/ldso/dlopen.c: stub_dlopen` → "Dynamic loading not supported"），真实 loader 只在 `libc.so` 里。静态可执行文件没有动态加载能力。
2. opentui 加载路径：opencode TUI 初始化时 `resolveRenderLib()` → `FFIRenderLib` → bun 的 `Bun.dlopen` → 原生 `dlopen()` 加载 `libopentui.so`，然后 `dlsym()` 逐符号绑定。在 musl 静态上这一步必然失败。
3. weak stub 可被 **strong 定义覆盖**；musl 内部从不调用 dlopen；bun 的 Rust/C++ 层**无需修改**（它只调 libc 的 dl* 函数）。

## 机制：静态链接代替加载，符号表代替解析

dlopen = 加载代码 + 解析符号。musl 静态下二者分别用：

- **加载** → 构建期把 opentui 以 `-Wl,--whole-archive` 静态链入 bun 可执行文件（代码已经在进程里，"加载"是空操作）。
- **解析** → 新增 C 文件 `src/dl-symtab.c`，定义 strong `dlopen/dlsym/dlclose/dlerror`，覆盖 musl 的 weak stub：
  - `dlopen()` 返回假句柄 `(void*)1`（永远成功）；
  - `dlsym()` 解析 `/proc/self/exe` 的 ELF `.symtab`，按名字查符号返回地址；
  - 因此可执行文件 **strip 时必须保留 `.symtab`**（musl 通道改用 `--strip-debug`）。

约束：dlsym 能查到的符号必须存在于可执行文件自身符号表 —— 全静态链接天然满足。

## 仓库布局（本仓库 = 唯一的修改载体）

```
oc/
├── src/dl-symtab.c               # dl* 拦截实现（strong 定义，ELF64 .symtab 解析）
├── src/dltest.c                  # musl dlopen 实证用的最小测试
├── patches/
│   ├── bun-flags-static.patch    # musl: -static；跳过 dynsym/version-script（对干净上游）
│   ├── bun-flags-dlopen.patch    # musl: 链 libopentui.a + dl-symtab.o；strip 保留 .symtab
│   └── opencode-build-targets.patch # 只编 linux-x64-musl 目标（OPENCODE_ONLY_LINUX_X64_MUSL）
├── docker/
│   ├── Dockerfile.bunmusl        # bun 构建环境（ubuntu24.04+LLVM21+nightly rust+musl sysroot）
│   └── Dockerfile.alpine-oc      # opencode 打包环境（alpine，嵌入静态 bun）
└── scripts/
    ├── env.sh                    # 路径/容器/代理/幂等 apply_patch
    ├── build-opentui.sh          # 克隆 anomalyco/opentui(v0.4.5 tag) → zig 交叉编译 libopentui.a
    ├── build-bun.sh              # 容器内构建 + 验证（.symtab、exports）
    ├── build-opencode.sh         # alpine 容器内构建 standalone
    └── verify-centos7.sh         # c7 容器全项验证
```

上游仓库（`bun/`、`opencode/`）**不被本仓库跟踪**，其源码修改仅通过 `scripts/*.sh` 里
`apply_patch`（幂等：已应用则跳过）临时施加，不产生持久差异之外的改动。

## 构建流程

1. `scripts/build-opentui.sh`（宿主触发，构建在容器 `bun-build` 内）
   - clone opentui，pin `v0.4.5`（与 npm 包 @opentui/core 0.4.5 同源，保证 FFI ABI 一致）
   - `zig cc -target x86_64-linux-musl` 编译 `dl-symtab.c` → `dl-symtab.o`
   - `zig build -Dstatic-lib=true`（容器内，zig 包依赖需网络）→ `libopentui.a`
   - **yoga C++ 不用 zig 编译**：zig cc 只支持自带 libc++（`std::__1` ABI），其运行时不在 bun 链接行上 → `build.zig` 在 static 模式改用系统 `clang++`（LLVM 21）+ musl sysroot 的 libstdc++ 15.2.0 逐文件编译 yoga 源码 → `libyoga_cxx.a`（独立产物，与 bun 自身 C++ 同一运行时）
   - 逐符号校验 FFI 导出；生成 `undefined.rsp`（lld GC roots）
2. `scripts/build-bun.sh`（容器 `bun-build`）
   - 产物拷入容器 `/opt/static/opentui/`（flags.ts 补丁中硬编码的绝对路径）
   - 幂等应用两个 bun 补丁 → `bun ./scripts/build.ts --profile=release --os=linux --arch=x64 --abi=musl --build-dir=build/release-musl-static -j4`
   - 链接行：`--whole-archive` 同时链入 `libopentui.a` + `libyoga_cxx.a` + `dl-symtab.o` + `-Wl,@undefined.rsp`
   - 校验：静态、`.symtab` 保留、opentui 导出符号在
3. `scripts/build-opencode.sh`（容器 `oc-build` = alpine-oc-build）
   - 静态 bun 拷为容器 `/usr/local/bin/bun`（宿主=目标 musl → `bun build --compile` 直接嵌入）
   - `OPENCODE_CHANNEL=dev OPENCODE_ONLY_LINUX_X64_MUSL=1 bun run script/build.ts --skip-embed-web-ui`
     （`--skip-embed-web-ui`：vite/rollup 需要 `.node` 原生模块，静态 musl bun 无加载器无法运行；跳过 web UI 嵌入不影响 TUI）
   - 产物：`packages/opencode/dist/opencode-linux-x64-musl/bin/opencode`
4. `scripts/verify-centos7.sh`（容器 `c7` = centos:7）
   - bun 基础；`bun:ffi` 的 `dlopen(libopentui.so)` 直测拦截层（注意 bun 的 FFI API 是 `bun:ffi` 模块，非 `Bun.dlopen`）；opencode `--version`、headless run、pty 下 TUI 冒烟

## 关键风险与对策

| 风险 | 对策 |
|---|---|
| opentui 仓库源码与 npm 包版本漂移（结构体布局不一致） | 克隆 pin 到 `v0.4.5` tag；构建后逐符号校验；必要时对齐到 npm 包的 gitHead |
| `.symtab` 体积增大（strip 只删 debug） | 实测 bun-profile 370MB 中含 symtab；构建后检查体积，若在意可裁剪 LOCAL 符号（保留 GLOBAL 即可满足 dlsym） |
| zig 版本与 opentui `build.zig.zon` 要求不符 | `ZIG_VERSION` 可覆盖；脚本先 `--help` 探测构建选项 |
| 链接冲突（zig 的 compiler_rt 与 bun 的重复符号） | 兜底路径已带 `-fno-compiler-rt`；冲突时按报错逐个处理 |
| 后续 bun 升级把补丁上下文弄坏 | 补丁即源码改动快照；`apply_patch` 双方向检查并明确报错 |

## 已知结论备忘

- 构建容器 `bun-build`（bun-musl-build-env）已含：ubuntu24.04、LLVM 21.1.8、
  nightly-2026-07-20、host bun 1.3.13、alpine 3.23 musl sysroot（`/opt/linux-sysroot-musl`）。
- CentOS 7 头less已验证（2026-08-05）：`--version` = 0.0.0-dev-202608050541；
  `run "say hi"` 走通 LLM 回复；仅 TUI 失败于 dlopen，即本方案修复点。
- 宿主代理 `http://172.18.48.1:7890`；容器内网络独立可用。
