/* STATE B — a half-fix: a share is taken only when `pin` is set. On the other path the pointer is
   still stored without one, so it is STILL COUNT_NO_SHARE. */
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

void CWE416_Use_After_Free__refcount_stored_without_share_12_bad(struct Holder *h, struct Buf *b, int pin)
{
    if (pin) buf_retain(b);
    if (h->buf) buf_release(h->buf);
    /* POTENTIAL FLAW: when `pin` is 0, no share goes with the stored pointer */
    h->buf = b;
}
