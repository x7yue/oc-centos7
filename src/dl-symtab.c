/*
 * dl-symtab.c — dlopen/dlsym/dlclose/dlerror interposition for fully-static
 * musl builds (bun + opencode running on CentOS 7).
 *
 * musl's libc.a only carries weak stubs of the dl* family (src/ldso/dlopen.c:
 * stub_dlopen → "Dynamic loading not supported"); a static executable has no
 * dynamic loader at all. OpenTUI is therefore linked into the executable at
 * build time (libopentui.a via -Wl,--whole-archive), and these STRONG
 * definitions shadow musl's weak stubs so Bun.dlopen():
 *   - "loads" a fake handle (everything is already in the executable), and
 *   - resolves symbols from the executable's own ELF .symtab, parsed from
 *     /proc/self/exe.
 *
 * Requirements:
 *   - the executable must retain .symtab after stripping (strip with
 *     --strip-debug for the musl lane, NOT --strip-all --discard-all), and
 *   - every requested symbol must be exported from the executable itself
 *     (guaranteed: the whole binary is one static link).
 *
 * Only dlopen/dlsym/dlclose/dlerror are interposed. dladdr/dlinfo/dlvsym are
 * left to musl's stubs, which fail gracefully (return 0/NULL) and bun does
 * not call in the OpenTUI load path.
 *
 * The /proc/self/exe mapping is deliberately kept for the process lifetime;
 * lookup is read-only afterwards.
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define HANDLE_SELF ((void *)1)

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static const Elf64_Sym *g_symtab;
static const char *g_strtab;
static size_t g_symcount;
static int g_parse_failed;

static __thread char tl_err[512];
static __thread int tl_has_err;

static void
set_err(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tl_err, sizeof(tl_err), fmt, ap);
    va_end(ap);
    tl_has_err = 1;
}

static void
clear_err(void)
{
    tl_has_err = 0;
}

static void
parse_self(void)
{
    char path[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (n <= 0) {
        set_err("dlopen: cannot read /proc/self/exe: %s", strerror(errno));
        g_parse_failed = 1;
        return;
    }
    path[n] = '\0';

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        set_err("dlopen: cannot open %s: %s", path, strerror(errno));
        g_parse_failed = 1;
        return;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(Elf64_Ehdr)) {
        close(fd);
        set_err("dlopen: cannot stat %s", path);
        g_parse_failed = 1;
        return;
    }

    /* mapping is kept for the process lifetime on purpose */
    const unsigned char *map = mmap(NULL, (size_t)st.st_size, PROT_READ,
                                    MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        set_err("dlopen: mmap %s failed: %s", path, strerror(errno));
        g_parse_failed = 1;
        return;
    }

    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)map;
    if (eh->e_ident[EI_MAG0] != ELFMAG0 || eh->e_ident[EI_MAG1] != ELFMAG1 ||
        eh->e_ident[EI_MAG2] != ELFMAG2 || eh->e_ident[EI_MAG3] != ELFMAG3 ||
        eh->e_ident[EI_CLASS] != ELFCLASS64 ||
        eh->e_ident[EI_DATA] != ELFDATA2LSB || eh->e_shoff == 0) {
        set_err("dlopen: %s is not a 64-bit little-endian ELF", path);
        g_parse_failed = 1;
        return;
    }

    const Elf64_Shdr *sh = (const Elf64_Shdr *)(map + eh->e_shoff);
    Elf64_Half shnum = eh->e_shnum;
    for (Elf64_Half i = 0; i < shnum; i++) {
        if (sh[i].sh_type != SHT_SYMTAB)
            continue;
        g_symtab = (const Elf64_Sym *)(map + sh[i].sh_offset);
        g_symcount = sh[i].sh_size / sizeof(Elf64_Sym);
        if (sh[i].sh_link < shnum)
            g_strtab = (const char *)(map + sh[sh[i].sh_link].sh_offset);
        break;
    }
    if (g_symtab == NULL || g_strtab == NULL) {
        set_err("dlopen: no .symtab in %s (was the binary stripped with --strip-all?)", path);
        g_parse_failed = 1;
    }
}

void *
dlopen(const char *file, int mode)
{
    (void)file;
    (void)mode;
    pthread_once(&g_once, parse_self);
    clear_err();
    if (g_parse_failed || g_symtab == NULL || g_strtab == NULL) {
        set_err("dlopen: executable symbol table unavailable");
        return NULL;
    }
    /* everything we could ever load is already linked in */
    return HANDLE_SELF;
}

void *
dlsym(void *handle, const char *name)
{
    (void)handle;
    pthread_once(&g_once, parse_self);
    clear_err();
    if (name == NULL) {
        set_err("dlsym: NULL symbol name");
        return NULL;
    }
    if (g_parse_failed || g_symtab == NULL || g_strtab == NULL) {
        set_err("dlsym: executable symbol table unavailable");
        return NULL;
    }
    for (size_t i = 0; i < g_symcount; i++) {
        const Elf64_Sym *s = &g_symtab[i];
        if (s->st_shndx == SHN_UNDEF)
            continue;
        unsigned char bind = ELF64_ST_BIND(s->st_info);
        unsigned char type = ELF64_ST_TYPE(s->st_info);
        if (bind == STB_LOCAL)
            continue;
        if (type == STT_TLS || type == STT_SECTION || type == STT_FILE ||
            type == STT_NOTYPE)
            continue;
        if (strcmp(g_strtab + s->st_name, name) == 0)
            return (void *)s->st_value;
    }
    set_err("dlsym: symbol not found: %s", name);
    return NULL;
}

int
dlclose(void *handle)
{
    (void)handle;
    return 0;
}

char *
dlerror(void)
{
    if (!tl_has_err)
        return NULL;
    /* musl semantics: return the error string and clear it */
    tl_has_err = 0;
    return tl_err;
}
