// @refcheck
#include <stdlib.h>
/* STATE B — a half-fix: `buf_reserve` is declared `@preserves` to make the caller pass. The
   declaration is checked against the body, which reallocates what it promised to leave in
   place: REF_NOT_PRESERVED. A declaration cannot make the pointer safe. */
/* CWE: 416 Use After Free (a function that reallocates, called as if it did not) */
struct Buf { char *data; unsigned len, cap; };

// @preserves(b)
void buf_reserve(struct Buf *b, unsigned n)
{
    if (n > b->cap) {
        /* POTENTIAL FLAW: the declaration above says this does not happen */
        b->data = realloc(b->data, n);
        b->cap = n;
    }
}

void CWE416_Use_After_Free__preserves_not_kept_08_bad(struct Buf *b)
{
    char *first = b->data;
    buf_reserve(b, 64);
    first[0] = 'x';
}
