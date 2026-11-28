/* STATE A — `b` is borrowed from the caller, and the function stores it in `h->buf` without
   taking a share. When the caller releases its own, the stored pointer dangles:
   COUNT_NO_SHARE. */
/* CWE: 416 Use After Free (stored pointer without a reference of its own) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);
struct Holder { struct Buf *buf; };

void CWE416_Use_After_Free__refcount_stored_without_share_12_bad(struct Holder *h, struct Buf *b)
{
    if (h->buf) buf_release(h->buf);
    /* POTENTIAL FLAW: `h->buf` now holds the object, but no share was taken for it */
    h->buf = b;
}
