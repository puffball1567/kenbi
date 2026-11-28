/* STATE C — one share received, one share released. GREEN. */
/* CWE: 415 Double Free (a reference released twice) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE415_Double_Free__refcount_released_twice_06_fixed(void)
{
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    int n = b->len;
    buf_release(b);   /* FIXED: the only release */
    return n;
}
