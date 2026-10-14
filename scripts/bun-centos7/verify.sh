#!/usr/bin/env bash
set -euo pipefail
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
cat /etc/centos-release
getconf GNU_LIBC_VERSION
uname -r
test -z "${LD_LIBRARY_PATH:-}"
ldd /artifacts/bun
if ldd /artifacts/bun | grep -q 'not found'; then exit 1; fi
/artifacts/bun --version
/artifacts/bun -e 'if (1 + 1 !== 2) throw new Error("JS failed"); console.log("JS_SMOKE=PASS")'
/artifacts/bun /artifacts/fixtures/dynamic.ts /artifacts/fixtures
echo 'CLEAN_CENTOS7_GLIBC217=PASS'
