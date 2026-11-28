// @kenbi file
// REFERENCE COUNTING: a type declared `@refcounted` is shared by counting references. Every
// holder of a pointer owns one share; kenbi follows the shares each function holds.
// Here `main` gives back a share twice and then uses the object, and `cache_set` replaces a
// stored pointer without releasing the one it held.
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
    g_cache = b;   //EXPECT COUNT_SLOT_OVERWRITTEN
}

int main(void) {
    Buf *b = buf_new(16);
    if (!b) return 1;
    cache_set(b);
    buf_release(b);
    buf_release(b);   //EXPECT COUNT_OVER_RELEASE
    return b->len;   //EXPECT COUNT_USE_AFTER_RELEASE
}
