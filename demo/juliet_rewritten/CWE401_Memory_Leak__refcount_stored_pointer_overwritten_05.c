/* STATE C — the old pointer is read out, the new one stored, and the old share released. GREEN. */
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

void CWE401_Memory_Leak__refcount_stored_pointer_overwritten_05_fixed(struct Holder *h, struct Buf *b)
{
    struct Buf *old = h->buf;
    buf_retain(b);
    h->buf = b;
    if (old) buf_release(old);   /* FIXED: the share the location held is given back */
}
