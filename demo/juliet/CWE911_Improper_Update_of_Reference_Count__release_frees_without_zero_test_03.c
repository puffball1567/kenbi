/* STATE A — the function declared as the release function decrements the counter and frees the
   object whatever the result. Every other holder is left with freed memory:
   COUNT_RELEASE_MISMATCH. */
/* CWE: 911 Improper Update of Reference Count */
#include <stdlib.h>
// @allocator demo::heap { alloc: malloc, free: free }
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @frees(b)
void buf_release(struct Buf *b)
{
    b->refs--;
    /* POTENTIAL FLAW: freed even when other shares remain */
    free(b);
}
