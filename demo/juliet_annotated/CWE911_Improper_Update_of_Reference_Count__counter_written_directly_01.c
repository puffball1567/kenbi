/* STATE B — a half-fix: the share is taken with `buf_retain`, but still given back by decrementing
   the field. It is STILL COUNT_DIRECT_WRITE. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

void work(void);

void CWE911_Improper_Update_of_Reference_Count__counter_written_directly_01_bad(struct Buf *b)
{
    buf_retain(b);
    work();
    /* POTENTIAL FLAW: if this was the last share, nothing frees the object */
    b->refs--;
}
