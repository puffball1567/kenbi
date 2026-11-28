/* STATE B — a half-fix: the second release is made conditional. On the path where the condition
   holds the share is still given back twice, so it is STILL COUNT_OVER_RELEASE. */
/* CWE: 415 Double Free (a reference released twice) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE415_Double_Free__refcount_released_twice_06_bad(int again)
{
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    int n = b->len;
    buf_release(b);
    /* POTENTIAL FLAW: when `again` is set, the one share is given back a second time */
    if (again) buf_release(b);
    return n;
}
