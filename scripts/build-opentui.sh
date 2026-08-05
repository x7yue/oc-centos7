#!/usr/bin/env bash
# Build OpenTUI as a static musl library + the dl-symtab shim object.
# Everything runs on the host (Ubuntu) — zig cross-compiles to musl by
# itself; no container needed.
#
# Output: $OUT/opentui/{libopentui.a, dl-symtab.o}
set -euo pipefail
source "$(dirname "$0")/env.sh"

OPENTUI_TAG="${OPENTUI_TAG:-v0.4.5}"          # tag matching @opentui/core 0.4.5 (npm)
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"          # opentui pins 0.15.2 (checkZigVersion)

mkdir -p "$OUT/logs" "$OPENTUI_OUT"

# --- 1. clone (pinned to the tag the npm package was built from) ---
if [ ! -d "$OPENTUI_REPO/.git" ]; then
    mkdir -p "$(dirname "$OPENTUI_REPO")"
    log "cloning anomalyco/opentui @ $OPENTUI_TAG"
    if ! git clone --depth 1 --branch "$OPENTUI_TAG" \
        https://github.com/anomalyco/opentui "$OPENTUI_REPO" 2>"$OUT/opentui-clone.log"; then
        err "tag $OPENTUI_TAG not found (see $OUT/opentui-clone.log); fall back with OPENTUI_TAG=main"
        exit 1
    fi
fi

# --- 2. zig toolchain (host glibc; targets musl) ---
ZIG_BIN="$OUT/zig-$ZIG_VERSION/zig"
if [ ! -x "$ZIG_BIN" ]; then
    log "downloading zig $ZIG_VERSION"
    mkdir -p "$(dirname "$ZIG_BIN")"
    curl -fSL --retry 5 \
        "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" \
        -o "$OUT/zig.tar.xz"
    tar -xJf "$OUT/zig.tar.xz" -C "$(dirname "$ZIG_BIN")" --strip-components=1
    rm -f "$OUT/zig.tar.xz"
fi
"$ZIG_BIN" version

# --- 3. dl-symtab.o via zig cc (bundled musl headers, no sysroot needed) ---
log "compiling dl-symtab.o (x86_64-linux-musl)"
"$ZIG_BIN" cc -target x86_64-linux-musl -O2 -c "$ROOT/src/dl-symtab.c" \
    -o "$OPENTUI_OUT/dl-symtab.o"

# --- 4. static libopentui.a (in the bun-build container: zig package deps
#        uucode/yoga need network; the host has none, the container does) ---
# The clone's build.zig hardcodes .linkage = .dynamic; our patch threads a
# -Dstatic-lib option through build() → buildSingleTarget() → buildTarget().
# linux-musl links only dl/pthread (inside libc) + in-tree yoga C++.
apply_patch "$OPENTUI_REPO" "$ROOT/patches/opentui-static-lib.patch"

ensure_running "$BUN_CONTAINER" "$BUN_IMAGE"
docker exec "$BUN_CONTAINER" sh -c 'rm -rf /opt/zig /opt/opentui && mkdir -p /opt/zig /opt/opentui'
docker cp "$(dirname "$ZIG_BIN")/." "$BUN_CONTAINER:/opt/zig/"
docker cp "$OPENTUI_REPO/packages/core/src/zig/." "$BUN_CONTAINER:/opt/opentui/"

mkdir -p "$OUT/logs"
log "zig build (x86_64-linux-musl, static) in $BUN_CONTAINER"
if ! docker exec "$BUN_CONTAINER" sh -c \
    'cd /opt/opentui && PATH=/opt/zig:$PATH zig build -Dtarget=x86_64-linux-musl \
       -Dstatic-lib=true -Doptimize=ReleaseFast build-x86_64-linux-musl' \
    >"$OUT/logs/opentui-build.log" 2>&1; then
    err "zig build failed — see $OUT/logs/opentui-build.log"; tail -30 "$OUT/logs/opentui-build.log"; exit 1
fi
docker cp "$BUN_CONTAINER:/opt/opentui/lib/x86_64-linux-musl/libopentui.a" "$OPENTUI_OUT/libopentui.a"
ls -la "$OPENTUI_OUT"

# --- 5. verify the FFI exports bun will look up ---
log "checking exports:"
for sym in setLogCallback createEventSink destroyEventSink createNativeRenderable \
           destroyNativeRenderable createRenderer destroyRenderer setTerminalEnvVar \
           setUseThread setClearOnShutdown setBackgroundColor render; do
    if nm "$OPENTUI_OUT/libopentui.a" 2>/dev/null | grep -qE " T $sym$"; then
        echo "  ok  $sym"
    else
        err "  MISSING  $sym"
        exit 1
    fi
done
echo "opentui build complete"
