/* STATE C — the function takes over the caller's share and gives it back with `buf_release`,
   which frees the object only if that was the last one. GREEN. */
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
void CWE416_Use_After_Free__refcount_freed_directly_14_fixed(struct Buf *b)
{
    buf_release(b);   /* FIXED: freed by the release function, at count zero */
}
