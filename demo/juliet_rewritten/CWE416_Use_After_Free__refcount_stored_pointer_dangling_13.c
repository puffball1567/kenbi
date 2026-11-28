/* STATE C — the pointer is cleared right after its share is released. GREEN. */
/* CWE: 416 Use After Free (stored pointer left behind after its reference was released) */
#include <stddef.h>
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);
struct Holder { struct Buf *buf; };

void CWE416_Use_After_Free__refcount_stored_pointer_dangling_13_fixed(struct Holder *h)
{
    if (!h->buf) return;
    buf_release(h->buf);
    h->buf = NULL;    /* FIXED: nothing is left to read */
}
