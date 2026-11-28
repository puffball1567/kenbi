/* STATE B — a half-fix: the share is released on the normal path, but an early return skips the
   release. On that path it is STILL COUNT_LEAK. */
/* CWE: 401 Memory Leak (a reference that is never released) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE401_Memory_Leak__refcount_share_not_released_04_bad(int limit)
{
    /* POTENTIAL FLAW: the early return below leaves with the share still held */
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    if (b->len > limit) return -1;
    int n = b->len;
    buf_release(b);
    return n;
}
