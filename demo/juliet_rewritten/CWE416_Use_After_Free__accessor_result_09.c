// @refcheck
/* STATE C — the accessor declares that its result points into `b`. A caller's copy of it is
   then followed like a pointer read out of the buffer, and here it is taken after the append.
   GREEN. */
/* CWE: 416 Use After Free — fixed by declaring what the accessor returns. */
struct Buf { char *data; unsigned len, cap; };

// @returns_into(b)
char *buf_data(struct Buf *b)
{
    return b->data;   /* FIXED: declared above */
}

// @invalidates(b)
void buf_append(struct Buf *b, const char *s);

void CWE416_Use_After_Free__accessor_result_09_fixed(struct Buf *b)
{
    buf_append(b, "abc");
    char *first = buf_data(b);
    first[0] = 'x';
}
