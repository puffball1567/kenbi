// @refcheck
/* STATE C — every function handed the buffer while the pointer is held declares that it
   reallocates and releases nothing there (each declaration is checked against the function's
   body where that is defined). GREEN. */
/* CWE: 416 Use After Free — fixed by declaring what each callee does to the buffer. */
struct Buf { char *data; unsigned len, cap; };

// @preserves(b)
void buf_normalise(struct Buf *b);
// @preserves(b)
void buf_trim(struct Buf *b);

void CWE416_Use_After_Free__undeclared_callee_07_fixed(struct Buf *b)
{
    char *first = b->data;
    buf_normalise(b);
    buf_trim(b);
    first[0] = 'x';
}
