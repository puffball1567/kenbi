/* STATE B — a half-fix: the old pointer is released only when `replace` is set. On the other path
   it is still overwritten, so it is STILL COUNT_SLOT_OVERWRITTEN. */
/* CWE: 401 Memory Leak (the reference a stored pointer held is lost) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);
struct Holder { struct Buf *buf; };

void CWE401_Memory_Leak__refcount_stored_pointer_overwritten_05_bad(struct Holder *h, struct Buf *b, int replace)
{
    buf_retain(b);
    if (replace) {
        if (h->buf) buf_release(h->buf);
    }
    /* POTENTIAL FLAW: when `replace` is 0 the old share is lost here */
    h->buf = b;
}
