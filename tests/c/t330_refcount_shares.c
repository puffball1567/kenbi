// @kenbi file
// REFERENCE COUNTING: what a function may do with the shares it holds. Each function below is
// either correct (no marker) or shows one way of breaking the discipline.
#include <stdlib.h>
#include <stdio.h>

// @allocator rc::heap { alloc: malloc calloc, free: free }
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
typedef struct Buf { int refs; int len; } Buf;
typedef struct Holder { Buf *buf; Buf *slots[4]; } Holder;

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
// @borrows(b)
void ext_use(Buf *b);
void ext_unknown(Buf *b);
// @moves(b)
void ext_take(Buf *b);
void other(void);

int leak(void) {                       // leak
    Buf *b = buf_new(4);   //EXPECT COUNT_LEAK
    if (!b) return 0;
    return b->len;
}
void borrowed_release(Buf *b) {        // releases the caller's share
    buf_release(b);   //EXPECT COUNT_OVER_RELEASE
}
// @frees(b)
void takes_and_releases(Buf *b) {      // ok
    buf_release(b);
}
void store_no_retain(Holder *h, Buf *b) {   // stored without a share
    if (h->buf) buf_release(h->buf);
    h->buf = b;   //EXPECT COUNT_NO_SHARE
}
void store_ok(Holder *h, Buf *b) {     // ok
    buf_retain(b);
    if (h->buf) buf_release(h->buf);
    h->buf = b;
}
int stale_after_call(Holder *h) {      // pointer read from storage, used after a call
    Buf *c = h->buf;
    if (!c) return 0;
    other();
    return c->len;   //EXPECT COUNT_USE_AFTER_RELEASE
}
int pinned_over_call(Holder *h) {      // ok
    Buf *c = h->buf;
    if (!c) return 0;
    buf_retain(c);
    other();
    int n = c->len;
    buf_release(c);
    return n;
}
void dangling_slot(Holder *h) {        // slot left dangling
    if (h->buf) buf_release(h->buf);   //EXPECT COUNT_SLOT_DANGLING
}
void pass_on(void) {                   // ok: hands the share over
    Buf *b = buf_new(1);
    if (!b) return;
    ext_use(b);
    ext_take(b);
}
void pass_twice(void) {                // hands over a share it no longer has
    Buf *b = buf_new(1);
    if (!b) return;
    ext_take(b);
    ext_take(b);   //EXPECT COUNT_NO_SHARE
}
void unknown_callee(Buf *b) {          // no contract
    ext_unknown(b);   //EXPECT COUNT_UNPROVEN
}
void direct_write(Buf *b) {            // 8
    b->refs = 5;   //EXPECT COUNT_DIRECT_WRITE
}
void direct_free(Buf *b) {             // 9
    free(b);   //EXPECT COUNT_DIRECT_FREE
}
void one_branch(int x) {               // leak on the path where x is 0
    Buf *b = buf_new(2);   //EXPECT COUNT_LEAK
    if (!b) return;
    if (x) buf_release(b);
}
// @frees(h)
void teardown(Holder *h) {             // ok
    for (int i = 0; i < 4; i++)
        if (h->slots[i]) buf_release(h->slots[i]);
    if (h->buf) buf_release(h->buf);
    free(h);
}
void loop_balanced(Buf *b, int n) {    // ok
    for (int i = 0; i < n; i++) {
        buf_retain(b);
        printf("%d\n", b->len);
        buf_release(b);
    }
}
void cleanup_goto(int x) {             // ok
    Buf *a = buf_new(1);
    Buf *b = NULL;
    if (!a) return;
    b = buf_new(2);
    if (!b) goto out;
    if (x) goto out2;
    ext_use(b);
out2:
    buf_release(b);
out:
    buf_release(a);
}
