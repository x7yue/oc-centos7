#!/usr/bin/env bash
# Build the OpenTUI v0.5 native archive and the static dlopen shim.
set -euo pipefail
source "$(dirname "$0")/env.sh"

OPENTUI_TAG="${OPENTUI_TAG:-$(read_ref opentui ref)}"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
PATCH_SHA="$(sha256sum "$ROOT/patches/opentui-static-lib.patch" | cut -d' ' -f1)"
DL_SHA="$(sha256sum "$ROOT/src/dl-symtab.c" | cut -d' ' -f1)"
SCRIPT_SHA="$(sha256sum "$ROOT/scripts/build-opentui.sh" | cut -d' ' -f1)"
SOURCE_SHA="$(cat "$OUT/upstream/opentui.sha" 2>/dev/null || git -C "$OPENTUI_REPO" rev-parse HEAD 2>/dev/null || true)"
MARKER="opentui=${SOURCE_SHA} zig=${ZIG_VERSION} patch=${PATCH_SHA} dl=${DL_SHA} script=${SCRIPT_SHA}"

if [ "${FORCE_REBUILD:-0}" != "1" ] && [ "$(cat "$OPENTUI_OUT/build-inputs.txt" 2>/dev/null)" = "$MARKER" ] \
    && [ -s "$OPENTUI_OUT/libopentui.a" ] && [ -s "$OPENTUI_OUT/libyoga_cxx.a" ] \
    && [ -s "$OPENTUI_OUT/dl-symtab.o" ] && [ -s "$OPENTUI_OUT/undefined.rsp" ]; then
    log "OpenTUI artifacts match pinned inputs; reusing cache"
    exit 0
fi

mkdir -p "$OUT/logs" "$OPENTUI_OUT"
rm -f "$OPENTUI_OUT/build-inputs.txt"
if [ ! -d "$OPENTUI_REPO/.git" ]; then
    mkdir -p "$(dirname "$OPENTUI_REPO")"
    git clone --depth 1 --branch "$OPENTUI_TAG" https://github.com/anomalyco/opentui "$OPENTUI_REPO"
fi
SOURCE_SHA="$(git -C "$OPENTUI_REPO" rev-parse HEAD)"
MARKER="opentui=${SOURCE_SHA} zig=${ZIG_VERSION} patch=${PATCH_SHA} dl=${DL_SHA} script=${SCRIPT_SHA}"

ZIG_BIN="$OUT/zig-$ZIG_VERSION/zig"
if [ ! -x "$ZIG_BIN" ]; then
    log "downloading Zig $ZIG_VERSION"
    mkdir -p "$(dirname "$ZIG_BIN")"
    curl -fSL --retry 5 \
        "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" \
        -o "$OUT/zig.tar.xz"
    tar -xJf "$OUT/zig.tar.xz" -C "$(dirname "$ZIG_BIN")" --strip-components=1
    rm -f "$OUT/zig.tar.xz"
fi
test "$("$ZIG_BIN" version)" = "$ZIG_VERSION"

log "compiling dl-symtab.o"
"$ZIG_BIN" cc -target x86_64-linux-musl -O2 -c "$ROOT/src/dl-symtab.c" \
    -o "$OPENTUI_OUT/dl-symtab.o"
apply_patch "$OPENTUI_REPO" "$ROOT/patches/opentui-static-lib.patch" '"static-lib"'

ensure_running "$BUN_CONTAINER" "$BUN_IMAGE" \
    -v "$BUN_REPO":/src/bun -w /src/bun \
    -e PATH=/usr/local/cargo/bin:/usr/lib/llvm-21/bin:/usr/local/bin:/usr/bin:/bin
docker exec "$BUN_CONTAINER" sh -c 'rm -rf /opt/zig /opt/opentui && mkdir -p /opt/zig /opt/opentui'
docker cp "$(dirname "$ZIG_BIN")/." "$BUN_CONTAINER:/opt/zig/"
docker cp "$OPENTUI_REPO/packages/native/." "$BUN_CONTAINER:/opt/opentui/"

log "building OpenTUI x86_64-linux-musl static archive"
if ! docker exec "$BUN_CONTAINER" sh -c \
    'cd /opt/opentui && sh scripts/prepare-zig-deps.sh && PATH=/opt/zig:$PATH zig build \
       -Dlibrary-target=x86_64-linux-musl -Dstatic-lib=true -Doptimize=ReleaseFast build-x86_64-linux-musl' \
    >"$OUT/logs/opentui-build.log" 2>&1; then
    err "OpenTUI build failed; see $OUT/logs/opentui-build.log"
    tail -50 "$OUT/logs/opentui-build.log"
    exit 1
fi
docker cp "$BUN_CONTAINER:/opt/opentui/lib/x86_64-linux-musl/libopentui.a" "$OPENTUI_OUT/libopentui.a"
docker cp "$BUN_CONTAINER:/opt/opentui/lib/x86_64-linux-musl/libyoga_cxx.a" "$OPENTUI_OUT/libyoga_cxx.a"

awk '/^export fn [[:alpha:]_][[:alnum:]_]*\(/ {
    sub(/^export fn /, "")
    sub(/\(.*/, "")
    print "--undefined=" $0
}' "$OPENTUI_REPO/packages/native/src/lib.zig" | sort -u > "$OPENTUI_OUT/undefined.rsp"
test -s "$OPENTUI_OUT/undefined.rsp"
if comm -23 \
    <(sed 's/^--undefined=//' "$OPENTUI_OUT/undefined.rsp") \
    <(nm -g --defined-only "$OPENTUI_OUT/libopentui.a" 2>/dev/null | awk '$2 ~ /^[TDBRW]$/ {print $3}' | sort -u) \
    | grep .; then
    err "OpenTUI FFI export missing from static archive"
    exit 1
fi
for sym in setLogCallback createEventSink destroyEventSink createNativeRenderable \
           destroyNativeRenderable createRenderer destroyRenderer setTerminalEnvVar \
           setUseThread setClearOnShutdown setBackgroundColor render; do
    if ! nm "$OPENTUI_OUT/libopentui.a" 2>/dev/null | grep -E " T $sym$" >/dev/null; then
        err "missing OpenTUI export: $sym"
        exit 1
    fi
done
printf '%s\n' "$MARKER" > "$OPENTUI_OUT/build-inputs.txt"
log "OpenTUI archive and FFI exports ready"
