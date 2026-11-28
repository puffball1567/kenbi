// @kenbi file
// REFERENCE COUNTING: the corrected program — every share taken is given back exactly once,
// a stored pointer is released before it is replaced, and nothing is used after the last
// share is gone. No findings.
#include <stdlib.h>

// @allocator rc::heap { alloc: malloc, free: free }
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
typedef struct Buf {
    int refs;
    int len;
    char *data;
} Buf;

// @owns
Buf *buf_new(int len) {
    Buf *b = malloc(sizeof(Buf));
    if (!b) return NULL;
    b->data = malloc((size_t)len);
    if (!b->data) { free(b); return NULL; }
    b->refs = 1;
    b->len = len;
    return b;
}

void buf_retain(Buf *b) {
    b->refs++;
}

// @frees(b)
// @frees(b.data)
void buf_release(Buf *b) {
    if (--b->refs == 0) {
        free(b->data);
        free(b);
    }
}

static Buf *g_cache;

void cache_set(Buf *b) {
    buf_retain(b);
    if (g_cache) buf_release(g_cache);
    g_cache = b;
}

// @owns
Buf *cache_get(void) {
    if (!g_cache) return NULL;
    buf_retain(g_cache);
    return g_cache;
}

void cache_clear(void) {
    if (g_cache) {
        buf_release(g_cache);
        g_cache = NULL;
    }
}

int main(void) {
    Buf *b = buf_new(16);
    if (!b) return 1;
    cache_set(b);
    int n = b->len;
    buf_release(b);
    Buf *c = cache_get();
    if (c) {
        n += c->len;
        buf_release(c);
    }
    cache_clear();
    return n;
}
