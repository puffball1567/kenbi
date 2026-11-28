/* STATE B — a half-fix: the release is moved after the read on one path only. On the other path
   the object is still read after the release, so it is STILL COUNT_USE_AFTER_RELEASE. */
/* CWE: 416 Use After Free (object used after the last reference was released) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE416_Use_After_Free__refcount_used_after_release_11_bad(int early)
{
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    if (early) buf_release(b);
    /* POTENTIAL FLAW: when `early` is set, the share is already gone here */
    int n = b->len;
    if (!early) buf_release(b);
    return n;
}
