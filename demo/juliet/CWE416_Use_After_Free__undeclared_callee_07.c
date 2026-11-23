// @refcheck
/* STATE A — a pointer into the buffer is held across two calls that are handed the buffer and
   say nothing about what they do to it. Nothing shows the storage stays in place:
   REF_UNPROVEN. */
/* CWE: 416 Use After Free (pointer kept across calls that may reallocate) */
struct Buf { char *data; unsigned len, cap; };

void buf_normalise(struct Buf *b);
void buf_trim(struct Buf *b);

void CWE416_Use_After_Free__undeclared_callee_07_bad(struct Buf *b)
{
    char *first = b->data;
    buf_normalise(b);
    buf_trim(b);
    /* POTENTIAL FLAW: either call may have moved the buffer */
    first[0] = 'x';
}
