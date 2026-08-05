#!/usr/bin/env bash
# Build OpenTUI as a static musl library + the dl-symtab shim object.
# Everything runs on the host (Ubuntu) — zig cross-compiles to musl by
# itself; no container needed.
#
# Output: $OUT/opentui/{libopentui.a, dl-symtab.o}
set -euo pipefail
source "$(dirname "$0")/env.sh"

OPENTUI_TAG="${OPENTUI_TAG:-v0.4.5}"          # tag matching @opentui/core 0.4.5 (npm)
ZIG_VERSION="${ZIG_VERSION:-0.15.1}"          # override if opentui requires another

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
mkdir -p "$OPENTUI_OUT"

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

# --- 4. static libopentui.a ---
cd "$OPENTUI_REPO"
log "opentui build files:"; ls build.zig build.zig.zon 2>/dev/null
log "shared/static options:"
"$ZIG_BIN" build --help 2>/dev/null | grep -iE "shared|static|target|release|optimize" || true

build_static() {
    # probe: which option name does this build.zig use for non-shared output?
    for opt in "-Dshared=false" "-Dbuild-mode=static" "-Dstatic=true" "-Dlink-libc=true"; do
        if "$ZIG_BIN" build --help 2>/dev/null | grep -qF "${opt%%=*}"; then
            log "trying: zig build $opt"
            "$ZIG_BIN" build "$opt" -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl 2>"$OUT/logs/opentui-build.log" \
                && return 0 || err "zig build $opt failed"
        fi
    done
    return 1
}

if ! build_static; then
    err "repo build did not produce a static lib; trying direct zig build-lib"
    ENTRY="$(grep -rlE "export fn (setLogCallback|createEventSink)" --include="*.zig" . | head -1)"
    [ -n "$ENTRY" ] || { err "could not locate the FFI entry zig file"; exit 1; }
    log "direct build-lib on: $ENTRY"
    "$ZIG_BIN" build-lib -target x86_64-linux-musl -O ReleaseFast -fno-compiler-rt \
        -femit-bin="$OPENTUI_OUT/libopentui.a" "$ENTRY" 2>"$OUT/logs/opentui-build.log" \
        || { err "direct build failed — see $OUT/logs/opentui-build.log"; exit 1; }
fi

# locate whatever static archive the repo build emitted
if [ ! -f "$OPENTUI_OUT/libopentui.a" ]; then
    A="$(find .zig-cache -name '*.a' ! -name '*compiler_rt*' 2>/dev/null | head -1)"
    [ -n "$A" ] || { err "no .a produced"; exit 1; }
    cp "$A" "$OPENTUI_OUT/libopentui.a"
fi
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
