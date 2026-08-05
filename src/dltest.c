#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

extern int opentui_test_add(int a, int b) { return a + b; }

int main() {
    void *h = dlopen(NULL, RTLD_LAZY);
    printf("dlopen(NULL) = %p\n", h);
    if (!h) printf("  dlerror: %s\n", dlerror());

    void *s = dlsym(RTLD_DEFAULT, "opentui_test_add");
    printf("dlsym(RTLD_DEFAULT) = %p\n", s);
    if (!s) printf("  dlerror: %s\n", dlerror());

    void *s2 = dlsym(h, "opentui_test_add");
    printf("dlsym(handle) = %p\n", s2);
    if (!s2) printf("  dlerror: %s\n", dlerror());
    return 0;
}
