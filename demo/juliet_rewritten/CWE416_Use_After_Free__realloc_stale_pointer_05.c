// @refcheck
/* STATE C — the pointer is taken after the call that may move the buffer, so it refers to
   where the buffer is now. GREEN. */
/* CWE: 416 Use After Free — fixed by taking the pointer after the reallocation. */
struct Buf { char *data; unsigned len, cap; };

// @invalidates(b)
void buf_append(struct Buf *b, const char *s);

void CWE416_Use_After_Free__realloc_stale_pointer_05_fixed(struct Buf *b)
{
    buf_append(b, "abc");
    char *first = b->data;   /* FIXED: taken after the append */
    first[0] = 'x';
}
