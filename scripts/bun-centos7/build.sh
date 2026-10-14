#!/usr/bin/env bash
set -euo pipefail
cd /src/bun
mkdir -p /out/evidence /out/fixtures /cache/cargo
export CARGO_TARGET_DIR=/cache/cargo
export CARGO_BUILD_JOBS=2
export CC=clang CXX=clang++
export BUN_TOOLCHAIN_LLVM=/opt/llvm21

test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
grep 'CentOS Linux release 7' /etc/centos-release
test "$(git rev-parse HEAD)" = 744846f844374847c902b5e7fd59b4342a51ef99
{
  cat /etc/centos-release
  getconf GNU_LIBC_VERSION
  rpm -q glibc glibc-devel kernel-headers
  uname -a
  clang++ --version
  rustc --version
  bun --version
  git rev-parse HEAD
  cat /opt/gcc13/packages.json
  printf '\n' | clang++ -std=c++23 -E -x c++ -v -
} > /out/evidence/toolchain.txt 2>&1

# Confirm modern C++ is available without replacing the system libc.
cat > /tmp/cxx-probe.cpp <<'CPP'
#include <expected>
#include <cstdio>
int main() { std::expected<int, int> value(42); printf("CXX23=%d\n", value.value()); }
CPP
clang++ -std=c++23 /tmp/cxx-probe.cpp -o /tmp/cxx-probe
ldd /tmp/cxx-probe | tee /out/evidence/cxx-ldd.txt
/tmp/cxx-probe

# Record the real compiler failure and the same failure after rollback on a copy.
source_file=src/jsc/bindings/workaround-missing-symbols.cpp
cp "$source_file" /out/evidence/ORIGINAL_FILE
sha256sum "$source_file" > /out/evidence/original.sha256
cp /repo/patches/bun-centos7-headers.patch /out/evidence/DIFF_FILE
cat > /out/evidence/ROLLBACK.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
test "$#" -eq 1
cp -- "$here/ORIGINAL_FILE" "$1"
cmp -- "$here/ORIGINAL_FILE" "$1"
SH
chmod +x /out/evidence/ROLLBACK.sh

compile_case() {
  local label=$1 input=$2 rc=0
  local log="/out/evidence/${label}.log"
  clang++ -std=gnu++23 -fPIC -c "$input" -o /tmp/header-check.o > "$log" 2>&1 || rc=$?
  {
    printf '%s COMMAND: clang++ -std=gnu++23 -fPIC -c %s -o /tmp/header-check.o\n' "$label" "$input"
    printf '%s INPUT_SHA256: ' "$label"
    sha256sum "$input"
    cat "$log"
    printf '%s EXIT_STATUS: %s\n' "$label" "$rc"
  } >> /out/evidence/VERIFICATION.txt
  return "$rc"
}
printf 'FIELD: native glibc 2.17 header compatibility; GNU ABI and dynamic libc\n' > /out/evidence/VERIFICATION.txt
if compile_case BASELINE "$source_file"; then
  echo 'Expected the pinned source to require newer glibc headers' >&2
  exit 1
fi
grep -q 'sys/random.h.*file not found' /out/evidence/BASELINE.log
git apply --check /repo/patches/bun-centos7-headers.patch
git apply /repo/patches/bun-centos7-headers.patch
cp "$source_file" /out/evidence/MODIFIED_FILE
compile_case MODIFIED "$source_file"
cp "$source_file" /tmp/rollback-source.cpp
/out/evidence/ROLLBACK.sh /tmp/rollback-source.cpp
if compile_case ROLLBACK /tmp/rollback-source.cpp; then
  echo 'Rollback did not restore baseline failure' >&2
  exit 1
fi
cmp /out/evidence/ORIGINAL_FILE /tmp/rollback-source.cpp
grep -q 'sys/random.h.*file not found' /out/evidence/ROLLBACK.log
printf 'ROLLBACK_RESULT: original bytes and baseline compiler failure restored; source remains patched\n' >> /out/evidence/VERIFICATION.txt
cat /out/evidence/VERIFICATION.txt

# Upstream release profile uses its pinned WebKit archive and disables LTO.
# Do not apply the musl/static OpenTUI or dlopen shim patches.
bun scripts/build.ts --profile=release --os=linux --arch=x64 --abi=gnu \
  --baseline=on --build-dir=/cache/build --cache-dir=/cache/deps -j2
install -m 755 /cache/build/bun /out/bun

# Build external libraries only AFTER Bun is linked.
clang -shared -fPIC /repo/tests/bun-centos7/add.c -o /out/fixtures/libexternal.so
clang -shared -fPIC -DBUILDING_NODE_EXTENSION -DNAPI_VERSION=8 \
  -I/src/bun/src/runtime/napi /repo/tests/bun-centos7/addon.c -o /out/fixtures/external.node
cp /repo/tests/bun-centos7/dynamic.ts /out/fixtures/
python /repo/scripts/bun-centos7/audit.py /out/bun /out/fixtures/*.so /out/fixtures/*.node \
  | tee /out/evidence/elf-audit.txt
/out/bun --version
/out/bun /out/fixtures/dynamic.ts /out/fixtures
sha256sum /out/bun /out/fixtures/* > /out/evidence/artifacts.sha256
