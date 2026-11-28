/* STATE C — one decrement per call, and the object is freed exactly where the decremented count
   is zero. GREEN. */
/* CWE: 911 Improper Update of Reference Count */
#include <stdlib.h>
// @allocator demo::heap { alloc: malloc, free: free }
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @frees(b)
void buf_release(struct Buf *b)
{
    if (--b->refs == 0) free(b);   /* FIXED */
}
