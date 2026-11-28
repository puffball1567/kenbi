/* STATE A — the function receives one share from `buf_new` and releases it twice. The second
   release gives back a share that belongs to another holder, or frees an object that is
   already gone: COUNT_OVER_RELEASE. */
/* CWE: 415 Double Free (a reference released twice) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE415_Double_Free__refcount_released_twice_06_bad(void)
{
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    int n = b->len;
    buf_release(b);
    /* POTENTIAL FLAW: this function held one share and has already given it back */
    buf_release(b);
    return n;
}
