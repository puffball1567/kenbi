/* STATE A — the share `h->buf` held is released, but the pointer stays in the structure. The next
   function that reads `h->buf` uses an object that may be freed: COUNT_SLOT_DANGLING. */
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

void CWE416_Use_After_Free__refcount_stored_pointer_dangling_13_bad(struct Holder *h)
{
    /* POTENTIAL FLAW: `h->buf` still holds the pointer when the function returns */
    if (h->buf) buf_release(h->buf);
}
