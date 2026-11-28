/* STATE C — the object is read while the function still holds its share, and released after.
   GREEN. */
/* CWE: 416 Use After Free (object used after the last reference was released) */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

int CWE416_Use_After_Free__refcount_used_after_release_11_fixed(void)
{
    struct Buf *b = buf_new(16);
    if (!b) return 0;
    int n = b->len;   /* FIXED: read before the release */
    buf_release(b);
    return n;
}
