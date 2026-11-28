/* STATE B — a half-fix: a zero test is added, but the decrement is dropped, so a call no longer
   gives a share back. It is STILL COUNT_RELEASE_MISMATCH. */
/* CWE: 911 Improper Update of Reference Count */
#include <stdlib.h>
// @allocator demo::heap { alloc: malloc, free: free }
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

/* POTENTIAL FLAW: the count is tested but never decremented */
// @frees(b)
void buf_release(struct Buf *b)
{
    if (b->refs == 0) free(b);
}
