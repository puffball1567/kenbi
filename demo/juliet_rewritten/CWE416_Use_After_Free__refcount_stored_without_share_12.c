/* STATE C — the function takes a share and that share goes into `h->buf` with the pointer.
   GREEN. */
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

void CWE416_Use_After_Free__refcount_stored_without_share_12_fixed(struct Holder *h, struct Buf *b)
{
    buf_retain(b);    /* FIXED: the share the holder will own */
    if (h->buf) buf_release(h->buf);
    h->buf = b;
}
