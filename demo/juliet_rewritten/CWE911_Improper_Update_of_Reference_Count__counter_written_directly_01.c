/* STATE C — the share is taken and given back through the type's own functions. GREEN. */
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

void CWE911_Improper_Update_of_Reference_Count__counter_written_directly_01_fixed(struct Buf *b)
{
    buf_retain(b);
    work();
    buf_release(b);   /* FIXED: the release function tests for zero and frees */
}
