#!/usr/bin/env bash
# GitHub Actions gate: exercise the shipped binaries inside CentOS 7.
set -euo pipefail
source "$(dirname "$0")/env.sh"

BIN="${BUN_BIN:-$BUN_REPO/build/release-musl-static/bun}"
OCBIN="${OPENCODE_BIN:-$OPENCODE_REPO/packages/cli/dist/cli-linux-x64-musl/bin/opencode}"
test -f "$BIN" || { err "Bun binary missing: $BIN"; exit 1; }
test -f "$OCBIN" || { err "OpenCode binary missing: $OCBIN"; exit 1; }
mkdir -p "$OUT/logs"

# The shim resolves symbols from the executable, independent of this path.
LIBSO="${OPENTUI_SO:-$OCBIN}"
ensure_running "$C7_CONTAINER" "$C7_IMAGE"
docker exec "$C7_CONTAINER" mkdir -p /opt/dist
docker cp "$BIN" "$C7_CONTAINER:/opt/dist/bun"
docker cp "$OCBIN" "$C7_CONTAINER:/opt/dist/opencode2"
docker cp "$LIBSO" "$C7_CONTAINER:/opt/dist/dlopen-target"
docker exec "$C7_CONTAINER" chmod +x /opt/dist/bun /opt/dist/opencode2

log "Bun runtime"
docker exec "$C7_CONTAINER" /opt/dist/bun --version
test "$(docker exec "$C7_CONTAINER" /opt/dist/bun -e 'console.log(2 + 2)')" = 4
if [ -n "${OC_BUILD_ID:-}" ]; then
    strings "$BIN" | grep -F "$OC_BUILD_ID" >/dev/null || { err "Bun build ID mismatch"; exit 1; }
    nm "$BIN" | grep ' oc_build_id$' >/dev/null || { err "Bun build ID symbol missing"; exit 1; }
fi

log "Bun FFI and embedded OpenTUI"
docker exec "$C7_CONTAINER" /opt/dist/bun -e '
  const { dlopen } = require("bun:ffi");
  const lib = dlopen("/opt/dist/dlopen-target", {
    render: { args: ["ptr"], returns: "int", threadsafe_function_mode: "never" },
    setLogCallback: { args: ["ptr"], returns: "void" },
  });
  if (!lib.symbols.render || !lib.symbols.setLogCallback) throw new Error("OpenTUI symbols absent");
  console.log("OpenTUI FFI symbols resolved");
'

log "OpenCode v2 CLI"
OCV="$(docker exec "$C7_CONTAINER" /opt/dist/opencode2 --version)"
printf 'opencode2 --version: %s\n' "$OCV"
if [ -n "${OC_VERSION:-}" ]; then
    test "$OCV" = "opencode2 v$OC_VERSION" || { err "OpenCode version mismatch: $OCV"; exit 1; }
fi
docker exec "$C7_CONTAINER" /opt/dist/opencode2 --help > "$OUT/logs/opencode-help.log"
grep -q 'serve' "$OUT/logs/opencode-help.log"
grep -q 'run' "$OUT/logs/opencode-help.log"
if [ -n "${OC_BUILD_ID:-}" ] && strings "$OCBIN" | grep '^oc-build:' >/dev/null; then
    strings "$OCBIN" | grep -F "$OC_BUILD_ID" >/dev/null || { err "OpenCode build ID mismatch"; exit 1; }
fi

log "OpenCode TUI in a CentOS 7 pty"
set +e
docker exec "$C7_CONTAINER" bash -c \
    'cd /tmp && TERM=xterm-256color timeout 20 script -qec /opt/dist/opencode2 /dev/null' \
    > "$OUT/logs/tui-centos7.log" 2>&1
tui_status=$?
set -e
if { [ "$tui_status" -ne 0 ] && [ "$tui_status" -ne 124 ]; } \
    || [ "$(wc -c < "$OUT/logs/tui-centos7.log")" -lt 100 ] \
    || ! grep -q 'OpenCode' "$OUT/logs/tui-centos7.log" \
    || grep -Eqi 'Failed to open library|Dynamic loading not supported|Error:|panic:' "$OUT/logs/tui-centos7.log"; then
    err "TUI smoke failed (status=$tui_status)"
    tail -60 "$OUT/logs/tui-centos7.log"
    exit 1
fi

log "OpenCode web server and embedded UI"
docker exec -d "$C7_CONTAINER" sh -c \
    'cd /tmp; /opt/dist/opencode2 serve --hostname 127.0.0.1 --port 4096 >/tmp/opencode-serve.log 2>&1 & echo $! >/tmp/opencode-serve.pid; wait'
cleanup_serve() {
    docker exec "$C7_CONTAINER" sh -c 'test ! -f /tmp/opencode-serve.pid || kill "$(cat /tmp/opencode-serve.pid)" 2>/dev/null || true' || true
}
trap cleanup_serve EXIT
ready=0
for _ in $(seq 1 20); do
    if docker exec "$C7_CONTAINER" /opt/dist/bun -e \
        'const r = await fetch("http://127.0.0.1:4096/"); const body = await r.text(); if (!r.ok || !/<html/i.test(body)) process.exit(1)' \
        >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    err "OpenCode web UI did not serve HTML"
    docker exec "$C7_CONTAINER" sh -c 'tail -80 /tmp/opencode-serve.log' || true
    exit 1
fi
log "CentOS 7 checks passed"
