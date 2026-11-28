/* STATE B — a half-fix: the pointer is cleared only when `clear` is set. On the other path it is
   left behind, so it is STILL COUNT_SLOT_DANGLING. */
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

void CWE416_Use_After_Free__refcount_stored_pointer_dangling_13_bad(struct Holder *h, int clear)
{
    if (!h->buf) return;
    /* POTENTIAL FLAW: when `clear` is 0, `h->buf` keeps the released pointer */
    buf_release(h->buf);
    if (clear) h->buf = NULL;
}
