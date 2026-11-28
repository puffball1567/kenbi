/* STATE A — the function receives a share from `buf_new` and returns without releasing it. The
   count never reaches zero, so the object is never freed: COUNT_LEAK. */
/* CWE: 401 Memory Leak (a reference that is never released) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE401_Memory_Leak__refcount_share_not_released_04_bad(void)
{
    /* POTENTIAL FLAW: the share received here is never given back */
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    return b->len;
}
