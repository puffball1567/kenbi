// @refcheck
/* STATE B — a half-fix: the pointer is taken again after the append, but only on one path. On
   the other path the old pointer is still used, so it is STILL REF_INVALIDATED. */
/* CWE: 416 Use After Free (pointer kept across a reallocation) */
struct Buf { char *data; unsigned len, cap; };

// @invalidates(b)
void buf_append(struct Buf *b, const char *s);

void CWE416_Use_After_Free__realloc_stale_pointer_05_bad(struct Buf *b, int refresh)
{
    char *first = b->data;
    buf_append(b, "abc");
    if (refresh) first = b->data;
    /* POTENTIAL FLAW: when `refresh` is 0, `first` is the pointer from before the append */
    first[0] = 'x';
}
