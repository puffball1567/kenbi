/* STATE C — both callees declare that they only use the object during the call. GREEN. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

// @borrows(b)
void log_buf(struct Buf *b);
// @borrows(b)
void audit_buf(struct Buf *b);

void CWE911_Improper_Update_of_Reference_Count__undeclared_callee_04_fixed(struct Buf *b)
{
    log_buf(b);       /* FIXED: declared, so the call is checked against the declaration */
    audit_buf(b);
}
