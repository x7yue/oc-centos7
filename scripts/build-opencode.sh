#!/usr/bin/env bash
# Build OpenCode v2 with the adapted static-musl Bun runtime.
# The upstream Bun in the Alpine image installs dependencies and builds the
# web UI; the adapted Bun is used only for the final standalone compile.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/validation.sh"

BUN_BIN="$BUN_REPO/build/release-musl-static/bun"
[ -f "$BUN_BIN" ] || { err "no static bun — run build-bun.sh first"; exit 1; }

OC_BIN="$OPENCODE_REPO/packages/cli/dist/cli-linux-x64-musl/bin/opencode"
oc_valid() {
    [ "${FORCE_REBUILD:-0}" = "1" ] && return 1
    [ -x "$OC_BIN" ] || return 1
    file "$OC_BIN" 2>/dev/null | grep -q "statically linked" || return 1
    [ -n "${OC_VERSION:-}" ] || return 1
    opencode_version_matches "$("$OC_BIN" --version 2>/dev/null)" "$OC_VERSION" || return 1
    if strings "$OC_BIN" 2>/dev/null | grep "oc-build:" >/dev/null; then
        [ -n "${OC_BUILD_ID:-}" ] || return 1
        strings "$OC_BIN" 2>/dev/null | grep -F "$OC_BUILD_ID" >/dev/null || return 1
    fi
    return 0
}
if oc_valid; then
    log "opencode artifact already valid — skipping build (FORCE_REBUILD=1 to rebuild)"
    ls -la "$OC_BIN"
    exit 0
fi

apply_patch "$OPENCODE_REPO" "$ROOT/patches/opencode-prebuilt-web-ui.patch" 'OPENCODE_PREBUILT_WEB_UI'
apply_patch "$OPENCODE_REPO" "$ROOT/patches/opencode-cli-name.patch" "OPENCODE_CLI_NAME: \"'opencode2'\""

# --- alpine container up ---
ensure_running "$ALPINE_CONTAINER" "$ALPINE_IMAGE" \
    -v "$OPENCODE_REPO":/src/opencode \
    -w /src/opencode

mkdir -p "$OUT/logs"
log "upstream bun: $(docker exec "$ALPINE_CONTAINER" bun --version)"
docker exec "$ALPINE_CONTAINER" sh -c 'cd /src/opencode && bun install --frozen-lockfile'
docker exec "$ALPINE_CONTAINER" sh -c 'cd /src/opencode/packages/cli && bun install --os="*" --cpu="*" @opentui/core@$(bun -p "require(\"./package.json\").dependencies[\"@opentui/core\"]") @opencode-ai/pty@$(bun -p "require(\"./package.json\").dependencies[\"@opencode-ai/pty\"]")'
docker exec "$ALPINE_CONTAINER" sh -c 'cd /src/opencode/packages/app && OPENCODE_CHANNEL=latest VITE_OPENCODE_SERVER_MODE=origin bun run build'

docker cp "$BUN_BIN" "$ALPINE_CONTAINER:/opt/oc-bun"
docker exec "$ALPINE_CONTAINER" chmod +x /opt/oc-bun
log "adapted bun: $(docker exec "$ALPINE_CONTAINER" /opt/oc-bun --version)"

log "building OpenCode v2 (linux-x64-musl only)..."
# OPENCODE_VERSION bakes the oc release id into the binary (--version,
# user-agent, MCP clientInfo); CI passes the exact upstream v2 version.
if ! docker exec -e OPENCODE_VERSION="${OC_VERSION:-}" -e OPENCODE_CHANNEL=latest \
    -e OPENCODE_PREBUILT_WEB_UI=1 "$ALPINE_CONTAINER" sh -c \
    'cd /src/opencode/packages/cli && /opt/oc-bun run script/build.ts --target=opencode-linux-x64-musl --skip-install' \
    >"$OUT/logs/opencode-build.log" 2>&1; then
    err "build failed — tail:"; tail -50 "$OUT/logs/opencode-build.log"; exit 1
fi
ls -la "$(dirname "$OC_BIN")"
log "build OK (log: $OUT/logs/opencode-build.log)"
log "opencode --version: $(docker exec "$ALPINE_CONTAINER" /src/opencode/packages/cli/dist/cli-linux-x64-musl/bin/opencode --version 2>&1)"
