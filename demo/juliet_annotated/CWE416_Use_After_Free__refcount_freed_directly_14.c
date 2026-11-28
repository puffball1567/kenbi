/* STATE B — a half-fix: the function now declares that it takes over the caller's share
   (`@frees(b)`), but it still frees the object instead of releasing that share. It is STILL
   COUNT_DIRECT_FREE. */
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

// @frees(b)
void CWE416_Use_After_Free__refcount_freed_directly_14_bad(struct Buf *b)
{
    /* POTENTIAL FLAW: owning one share does not mean owning the last one */
    free(b);
}
