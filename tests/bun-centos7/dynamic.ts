import { strict as assert } from "node:assert";
import { dlopen, FFIType } from "bun:ffi";
import { createRequire } from "node:module";
import { join } from "node:path";

const dir = process.argv[2];
assert.ok(dir, "fixture directory required");
const lib = dlopen(join(dir, "libexternal.so"), {
  centos7_external_add: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
});
assert.equal(lib.symbols.centos7_external_add(19, 23), 42);
lib.close();
console.log("FFI_EXTERNAL_SO=42");
assert.throws(() => dlopen(join(dir, "missing.so"), {
  centos7_external_add: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
}));
console.log("FFI_MISSING_SO=REJECTED");
const require = createRequire(import.meta.url);
const addon = require(join(dir, "external.node"));
assert.equal(addon.add(19, 23), 42);
assert.throws(() => addon.add("bad", 1));
console.log("NAPI_EXTERNAL_NODE=42");
console.log("DYNAMIC_LOADING=PASS");
