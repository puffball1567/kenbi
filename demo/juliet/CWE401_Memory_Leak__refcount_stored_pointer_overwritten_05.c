/* STATE A — `h->buf` may already point to an object and hold a share of it. Assigning over it
   loses that share, so that object is never freed: COUNT_SLOT_OVERWRITTEN. */
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

void CWE401_Memory_Leak__refcount_stored_pointer_overwritten_05_bad(struct Holder *h, struct Buf *b)
{
    buf_retain(b);
    /* POTENTIAL FLAW: whatever `h->buf` held is overwritten with its share still out */
    h->buf = b;
}
