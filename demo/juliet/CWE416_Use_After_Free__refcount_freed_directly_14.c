/* STATE A — the object is passed to `free` whatever its count. Every other holder is left with a
   pointer to freed memory: COUNT_DIRECT_FREE. */
/* CWE: 416 Use After Free (shared object freed while references remain) */
#include <stdlib.h>
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

void CWE416_Use_After_Free__refcount_freed_directly_14_bad(struct Buf *b)
{
    /* POTENTIAL FLAW: other holders may still have shares of `b` */
    free(b);
}
