// @refcheck
/* STATE B — a half-fix: one of the two calls is declared to leave the buffer in place. The
   other still declares nothing, so the pointer is STILL REF_UNPROVEN after it. */
/* CWE: 416 Use After Free (pointer kept across calls that may reallocate) */
struct Buf { char *data; unsigned len, cap; };

// @preserves(b)
void buf_normalise(struct Buf *b);
void buf_trim(struct Buf *b);

void CWE416_Use_After_Free__undeclared_callee_07_bad(struct Buf *b)
{
    char *first = b->data;
    buf_normalise(b);
    buf_trim(b);
    /* POTENTIAL FLAW: `buf_trim` declares nothing about the buffer */
    first[0] = 'x';
}
