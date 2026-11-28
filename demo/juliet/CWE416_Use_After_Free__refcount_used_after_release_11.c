/* STATE A — the function releases its only share and then reads the object. If that was the last
   share the object is freed: COUNT_USE_AFTER_RELEASE. */
/* CWE: 416 Use After Free (object used after the last reference was released) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE416_Use_After_Free__refcount_used_after_release_11_bad(void)
{
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    buf_release(b);
    /* POTENTIAL FLAW: nothing this function holds keeps `b` alive any more */
    return b->len;
}
