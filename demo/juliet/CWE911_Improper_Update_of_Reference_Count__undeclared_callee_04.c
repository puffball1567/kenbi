/* STATE A — `log_buf` has no body here and no contract: it may only read the object, or it may
   keep the pointer or release a share. kenbi does not guess: COUNT_UNPROVEN. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

void log_buf(struct Buf *b);
void audit_buf(struct Buf *b);

void CWE911_Improper_Update_of_Reference_Count__undeclared_callee_04_bad(struct Buf *b)
{
    /* POTENTIAL FLAW: nothing says whether these calls keep or release `b` */
    log_buf(b);
    audit_buf(b);
}
