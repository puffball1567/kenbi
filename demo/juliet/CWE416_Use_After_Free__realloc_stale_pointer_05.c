// @refcheck
/* STATE A — a pointer into the buffer is taken, the buffer is appended to (which may reallocate
   it, as `buf_append` declares), and the old pointer is used. kenbi follows the pointer under
   @refcheck: REF_INVALIDATED. */
/* CWE: 416 Use After Free (pointer kept across a reallocation) */
struct Buf { char *data; unsigned len, cap; };

// @invalidates(b)
void buf_append(struct Buf *b, const char *s);

void CWE416_Use_After_Free__realloc_stale_pointer_05_bad(struct Buf *b)
{
    char *first = b->data;
    buf_append(b, "abc");
    /* POTENTIAL FLAW: `first` points where the buffer was before the append */
    first[0] = 'x';
}
