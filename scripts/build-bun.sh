#!/usr/bin/env bash
# Build bun fully-static musl with OpenTUI linked in + dlopen interposition.
# Runs inside the bun-musl-build-env container (host bun for scripts, LLVM 21,
# pinned nightly rust, alpine musl sysroot). Upstream repos are NOT modified:
# the changes live in this repo's patches/ and are applied idempotently.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ -f "$OPENTUI_OUT/libopentui.a" ] || "$ROOT/scripts/build-opentui.sh"

# --- 1. build container up ---
ensure_running "$BUN_CONTAINER" "$BUN_IMAGE" \
    -v "$BUN_REPO":/src/bun \
    -w /src/bun \
    -e CARGO_BUILD_JOBS=2 \
    -e PATH=/usr/local/cargo/bin:/usr/lib/llvm-21/bin:/usr/local/bin:/usr/bin:/bin

# --- 2. stage opentui artifacts at the hardcoded /opt/static paths (flags.ts patch) ---
docker exec "$BUN_CONTAINER" sh -c 'rm -rf /opt/static/opentui && mkdir -p /opt/static/opentui'
docker cp "$OPENTUI_OUT/libopentui.a" "$BUN_CONTAINER:/opt/static/opentui/libopentui.a"
docker cp "$OPENTUI_OUT/dl-symtab.o"  "$BUN_CONTAINER:/opt/static/opentui/dl-symtab.o"

# --- 3. apply patches (idempotent) ---
apply_patch "$BUN_REPO" "$ROOT/patches/bun-flags-static.patch"
apply_patch "$BUN_REPO" "$ROOT/patches/bun-flags-dlopen.patch"

# --- 4. build (incremental — only link + strip change) ---
mkdir -p "$OUT/logs"
log "building (profile=release, linux x64 musl)..."
if ! docker exec "$BUN_CONTAINER" bash -c \
    'bun ./scripts/build.ts --profile=release --os=linux --arch=x64 --abi=musl \
       --build-dir=build/release-musl-static -j4' >"$OUT/logs/bun-build.log" 2>&1; then
    err "build failed — tail:"; tail -50 "$OUT/logs/bun-build.log"; exit 1
fi
log "build OK (log: $OUT/logs/bun-build.log)"

# --- 5. verify ---
BIN="$BUN_REPO/build/release-musl-static/bun"
PROFILE_BIN="$BUN_REPO/build/release-musl-static/bun-profile"
file "$BIN"
echo "--- ldd:"; ldd "$BIN" 2>&1 || true
echo "--- .symtab kept? (must be >0):"
nm "$BIN" 2>/dev/null | grep -cE " T (render|setLogCallback|createEventSink)$" || true
echo "--- sizes:"; ls -la "$BIN" "$PROFILE_BIN" 2>/dev/null || true
