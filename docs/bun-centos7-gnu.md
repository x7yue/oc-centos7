# Bun native CentOS 7 / glibc 2.17 experiment

Branch: `verify/bun-centos7-glibc217`. Workflow: `bun-centos7-gnu.yml`.
Only Bun is built. Compilation and execution run in GitHub Actions, inside
CentOS 7 containers. The Ubuntu runner only hosts Docker.

The experiment pins Bun `bun-v1.4.2` to commit
`744846f844374847c902b5e7fd59b4342a51ef99`, uses the upstream GNU release profile,
and retains the upstream pinned prebuilt WebKit archive. This is not a rebuild
of WebKit. LLVM 21 runs natively in a manylinux2014 CentOS 7 userland. GCC 13
headers and static C++ support libraries are imported separately; libc, its
headers, and the ELF interpreter remain CentOS 7's system glibc 2.17.

The separate header patch accommodates old system headers. The c-ares build
configuration uses its existing `/dev/urandom` implementation instead of
assuming newer glibc random APIs and headers. Baseline, patched,
and rolled-back compiler invocations and source hashes are included in the
artifact. No static musl, OpenTUI, OpenCode, or fake `dlopen` patches are applied.
The syscall patch supplies the x86-64 `preadv2`/`pwritev2` numbers and
`RWF_NOWAIT` flag missing from the old Linux headers, preserving upstream calls.

Acceptance criteria:

- Bun is compiled in a verified CentOS 7 / glibc 2.17 container.
- Its interpreter is `/lib64/ld-linux-x86-64.so.2`; it dynamically needs
  `libc.so.6`, imports system `dlopen`, and has no `GLIBC_*` requirement above 2.17.
- A fresh CentOS 7 container without the build toolchain runs Bun and JS.
- `bun:ffi` loads and calls a separately compiled `.so`, and rejects a missing file.
- `require()` loads a separately compiled Node-API `.node` and calls its export.

Both external libraries are built after linking Bun. A pass cannot be produced
by resolving prelinked fixture symbols from the executable.

CentOS 7 containers share the runner's Linux kernel. Passing this experiment
establishes the glibc and dynamic-loader behavior on that kernel; compatibility
with CentOS 7's original 3.10 kernel needs a separate VM test. A minimal Node-API
fixture does not establish support for every addon, V8 ABI, or C++ runtime ABI.

Pushes affecting this experiment run it automatically. After the workflow has
been registered, it can also be rerun with:

```bash
gh workflow run bun-centos7-gnu.yml --ref verify/bun-centos7-glibc217
```

Results live in the build and runtime artifacts of each Actions run. The current
musl release workflow is independent of this experiment.
