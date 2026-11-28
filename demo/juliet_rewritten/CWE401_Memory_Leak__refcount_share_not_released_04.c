/* STATE C — every path that leaves the function gives the share back. GREEN. */
/* CWE: 401 Memory Leak (a reference that is never released) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE401_Memory_Leak__refcount_share_not_released_04_fixed(int limit)
{
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    int n = b->len;
    buf_release(b);   /* FIXED: released before either return */
    if (n > limit) return -1;
    return n;
}
