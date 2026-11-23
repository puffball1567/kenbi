// @refcheck
#include <stdlib.h>
/* STATE C — `buf_reserve` declares what it does (`@invalidates`), and the caller takes its
   pointer after the call. GREEN. */
/* CWE: 416 Use After Free — fixed by declaring the reallocation and taking the pointer after. */
struct Buf { char *data; unsigned len, cap; };

// @invalidates(b)
void buf_reserve(struct Buf *b, unsigned n)
{
    if (n > b->cap) {
        b->data = realloc(b->data, n);
        b->cap = n;
    }
}

void CWE416_Use_After_Free__preserves_not_kept_08_fixed(struct Buf *b)
{
    buf_reserve(b, 64);
    char *first = b->data;   /* FIXED: taken after the call that may move the buffer */
    first[0] = 'x';
}
