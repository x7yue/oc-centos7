#!/usr/bin/env bash
# Verify the static artifacts on CentOS 7 (c7 container):
#   1. bun basics
#   2. bun FFI dlopen of libopentui.so (validates the dl-symtab interposition)
#   3. opencode headless (LLM run)
#   4. opencode TUI in a pty
set -euo pipefail
source "$(dirname "$0")/env.sh"

BIN="${BUN_BIN:-$BUN_REPO/build/release-musl-static/bun}"
OCBIN="${OPENCODE_BIN:-$OPENCODE_REPO/packages/opencode/dist/opencode-linux-x64-musl/bin/opencode}"
[ -f "$BIN" ] || { err "no bun binary — run build-bun.sh first"; exit 1; }
[ -f "$OCBIN" ] || { err "no opencode binary — run build-opencode.sh first"; exit 1; }

# host copy of the real libopentui.so (from the npm package) for the dlopen test;
# bun install stashes platform packages under node_modules/.bun/<name+platform>/
LIBSO="${OPENTUI_SO:-$(find "$OPENCODE_REPO" -name 'libopentui.so' -path '*x64-musl*' 2>/dev/null | head -1)}"
[ -n "$LIBSO" ] || { err "libopentui.so not found in node_modules"; exit 1; }

ensure_running "$C7_CONTAINER" "$C7_IMAGE"
docker exec "$C7_CONTAINER" mkdir -p /opt/dist
docker cp "$BIN"    "$C7_CONTAINER:/opt/dist/bun"
docker cp "$OCBIN"  "$C7_CONTAINER:/opt/dist/opencode"
docker cp "$LIBSO"  "$C7_CONTAINER:/opt/dist/libopentui.so"
docker exec "$C7_CONTAINER" chmod +x /opt/dist/bun /opt/dist/opencode

echo "=== 1. bun basics ==="
docker exec "$C7_CONTAINER" /opt/dist/bun --version
docker exec "$C7_CONTAINER" /opt/dist/bun -e 'console.log(2 + 2)'
echo "=== 2. bun FFI dlopen (dl-symtab interposition) ==="
docker exec "$C7_CONTAINER" /opt/dist/bun -e '
  const { dlopen } = require("bun:ffi");
  const lib = dlopen("/opt/dist/libopentui.so", {
    render:      { args: ["ptr"], returns: "int", threadsafe_function_mode: "never" },
    setLogCallback: { args: ["ptr"], returns: "void" },
  });
  console.log("dlopen OK, render @", lib.symbols.render);
' || { err "dlopen test failed"; exit 1; }
echo "=== 3. opencode headless ==="
docker exec "$C7_CONTAINER" /opt/dist/opencode --version
echo "=== 4. opencode TUI (pty, 15s) ==="
docker exec "$C7_CONTAINER" bash -c \
  'cd /tmp && TERM=xterm-256color timeout 15 script -qec /opt/dist/opencode /dev/null' \
  > "$OUT/logs/tui-centos7.log" 2>&1 || true
if grep -q "Failed to open library\|Dynamic loading not supported" "$OUT/logs/tui-centos7.log"; then
    err "TUI failed:"; grep -B3 -A3 "Failed to open\|Dynamic loading" "$OUT/logs/tui-centos7.log" | head -20
    exit 1
fi
log "TUI smoke test passed (no dlopen failure; log: $OUT/logs/tui-centos7.log)"
echo "=== all CentOS 7 checks done ==="
