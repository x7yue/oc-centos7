#!/usr/bin/env bash
# Build the opencode standalone binary with our fully-static musl bun.
# Runs in the alpine container; host bun == target (musl), so
# `bun build --compile` embeds our static runtime.
set -euo pipefail
source "$(dirname "$0")/env.sh"

BUN_BIN="$BUN_REPO/build/release-musl-static/bun"
[ -f "$BUN_BIN" ] || { err "no static bun — run build-bun.sh first"; exit 1; }

# --- 0. artifact reuse. The CI cache key encodes <opencode ref>-<bun ref>;
#      a statically-linked existing binary is the product of these inputs.
#      Identity checks: OPENCODE_VERSION bakes the oc release version into
#      --version (CI sets OC_VERSION). The embedded bun runtime carries the
#      oc-build: marker; if the marker is visible in the exe it must still
#      match the current build id (a stale day-1 cache would otherwise embed
#      a stale runtime), but if the runtime is embedded compressed and the
#      marker is invisible, presence is unknowable and we rely on --version.
#      FORCE_REBUILD=1 bypasses.
OC_BIN="$OPENCODE_REPO/packages/opencode/dist/opencode-linux-x64-musl/bin/opencode"
oc_valid() {
    [ "${FORCE_REBUILD:-0}" = "1" ] && return 1
    [ -x "$OC_BIN" ] || return 1
    file "$OC_BIN" 2>/dev/null | grep -q "statically linked" || return 1
    if strings "$OC_BIN" 2>/dev/null | grep -q "oc-build:"; then
        [ -n "${OC_BUILD_ID:-}" ] || return 1
        strings "$OC_BIN" 2>/dev/null | grep -qF "$OC_BUILD_ID" || return 1
    fi
}
if oc_valid; then
    log "opencode artifact already valid — skipping build (FORCE_REBUILD=1 to rebuild)"
    ls -la "$OC_BIN"
    exit 0
fi

apply_patch "$OPENCODE_REPO" "$ROOT/patches/opencode-build-targets.patch" 'OPENCODE_ONLY_LINUX_X64_MUSL'

# --- alpine container up ---
ensure_running "$ALPINE_CONTAINER" "$ALPINE_IMAGE" \
    -v "$OPENCODE_REPO":/src/opencode \
    -w /src/opencode

docker cp "$BUN_BIN" "$ALPINE_CONTAINER:/usr/local/bin/bun"
docker exec "$ALPINE_CONTAINER" chmod +x /usr/local/bin/bun
log "container bun: $(docker exec "$ALPINE_CONTAINER" bun --version)"

mkdir -p "$OUT/logs"
docker exec "$ALPINE_CONTAINER" sh -c 'cd /src/opencode && bun install --ignore-scripts'

log "building opencode (linux-x64-musl only)..."
# OPENCODE_VERSION bakes the oc release id into the binary (--version,
# user-agent, MCP clientInfo); CI passes OC_VERSION, e.g. 1.4.9-oc-20260806-6b6fb1aa.
if ! docker exec -e OPENCODE_VERSION="${OC_VERSION:-}" "$ALPINE_CONTAINER" sh -c \
    'cd /src/opencode/packages/opencode && OPENCODE_CHANNEL=dev OPENCODE_ONLY_LINUX_X64_MUSL=1 bun run script/build.ts --skip-embed-web-ui' \
    >"$OUT/logs/opencode-build.log" 2>&1; then
    err "build failed — tail:"; tail -50 "$OUT/logs/opencode-build.log"; exit 1
fi
ls -la "$OPENCODE_REPO/packages/opencode/dist/opencode-linux-x64-musl/bin/"
log "build OK (log: $OUT/logs/opencode-build.log)"
log "opencode --version: $(docker exec "$ALPINE_CONTAINER" /src/opencode/packages/opencode/dist/opencode-linux-x64-musl/bin/opencode --version 2>&1 || true)"
