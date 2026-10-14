#include <node_api.h>

static napi_value add(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2], result;
    int32_t a, b;
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 2 ||
        napi_get_value_int32(env, argv[0], &a) != napi_ok ||
        napi_get_value_int32(env, argv[1], &b) != napi_ok) {
        napi_throw_type_error(env, NULL, "two integers required");
        return NULL;
    }
    napi_create_int32(env, a + b, &result);
    return result;
}
NAPI_MODULE_INIT() {
    napi_value fn;
    napi_create_function(env, "add", NAPI_AUTO_LENGTH, add, NULL, &fn);
    napi_set_named_property(env, exports, "add", fn);
    return exports;
}
