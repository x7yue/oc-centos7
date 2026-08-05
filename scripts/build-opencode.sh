#!/usr/bin/env bash
# Build the opencode standalone binary with our fully-static musl bun.
# Runs in the alpine container; host bun == target (musl), so
# `bun build --compile` embeds our static runtime.
set -euo pipefail
source "$(dirname "$0")/env.sh"

BUN_BIN="$BUN_REPO/build/release-musl-static/bun"
[ -f "$BUN_BIN" ] || { err "no static bun — run build-bun.sh first"; exit 1; }

apply_patch "$OPENCODE_REPO" "$ROOT/patches/opencode-build-targets.patch"

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
if ! docker exec "$ALPINE_CONTAINER" sh -c \
    'cd /src/opencode/packages/opencode && OPENCODE_CHANNEL=dev OPENCODE_ONLY_LINUX_X64_MUSL=1 bun run script/build.ts' \
    >"$OUT/logs/opencode-build.log" 2>&1; then
    err "build failed — tail:"; tail -50 "$OUT/logs/opencode-build.log"; exit 1
fi
ls -la "$OPENCODE_REPO/packages/opencode/dist/opencode-linux-x64-musl/bin/"
log "build OK (log: $OUT/logs/opencode-build.log)"
