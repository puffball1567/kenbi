// @refcheck
#include <stdlib.h>
/* STATE A — `buf_reserve` reallocates the buffer and declares nothing, and its caller keeps a
   pointer across the call. The caller's use is REF_UNPROVEN: nothing says the buffer stays. */
/* CWE: 416 Use After Free (a function that reallocates, called as if it did not) */
struct Buf { char *data; unsigned len, cap; };

void buf_reserve(struct Buf *b, unsigned n)
{
    if (n > b->cap) {
        b->data = realloc(b->data, n);
        b->cap = n;
    }
}

void CWE416_Use_After_Free__preserves_not_kept_08_bad(struct Buf *b)
{
    char *first = b->data;
    buf_reserve(b, 64);
    /* POTENTIAL FLAW: `buf_reserve` may have moved the buffer */
    first[0] = 'x';
}
