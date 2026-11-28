// @kenbi file
// REFERENCE COUNTING: pointers kept in storage (fields, globals). The location holds the
// share; reading the pointer out gives no share, replacing it must account for the one it
// held, and copying a holder whole duplicates pointers without shares.
#include <stdlib.h>
#include <string.h>

// @allocator rc::heap { alloc: malloc calloc, free: free }
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
typedef struct Buf { int refs; int len; } Buf;
typedef struct Holder { Buf *buf; } Holder;

// @owns
Buf *buf_new(int len) {
    Buf *b = malloc(sizeof(Buf));
    if (!b) return NULL;
    b->refs = 1;
    b->len = len;
    return b;
}
void buf_retain(Buf *b) { b->refs++; }
// @frees(b)
void buf_release(Buf *b) {
    if (--b->refs == 0) free(b);
}
int inspect(Buf *b) { return b->len; }
static Buf *g_a, *g_b;

int pass_unpinned(Holder *h) {            // passed while only the stored pointer keeps it
    if (!h->buf) return 0;
    return inspect(h->buf);   //EXPECT COUNT_USE_AFTER_RELEASE
}
int pass_pinned(Holder *h) {              // ok
    Buf *c = h->buf;
    if (!c) return 0;
    buf_retain(c);
    int n = inspect(c);
    buf_release(c);
    return n;
}
void replace(Holder *h, Buf *b) {         // ok: the old pointer is kept and released after
    Buf *old = h->buf;
    buf_retain(b);
    h->buf = b;
    if (old) buf_release(old);
}
// @owns
Buf *take(Holder *h) {                    // ok: the share moves out with the pointer
    Buf *t = h->buf;
    h->buf = NULL;
    return t;
}
void move_between(void) {                 // ok: a move between two stored pointers
    if (g_b) return;
    g_b = g_a;
    g_a = NULL;
}
void copy_between(void) {                 // both hold it, one share
    if (g_b) return;
    g_b = g_a;   //EXPECT COUNT_NO_SHARE
}
void struct_copy(Holder *dst, Holder *src) {   // 3
    *dst = *src;   //EXPECT COUNT_UNPROVEN
}
void mem_copy(Holder *dst, Holder *src) {      // 4
    memcpy(dst, src, sizeof *dst);   //EXPECT COUNT_UNPROVEN
}
int scoped_holder(void) {                 // the share dies with the local struct
    Holder h;
    h.buf = buf_new(3);
    return 0;   //EXPECT COUNT_LEAK
}
int scoped_holder_ok(void) {              // ok
    Holder h;
    h.buf = buf_new(3);
    if (h.buf) buf_release(h.buf);
    return 0;
}
Holder make_holder(void) {                // ok: the holder is returned whole
    Holder h;
    h.buf = buf_new(3);
    return h;
}
