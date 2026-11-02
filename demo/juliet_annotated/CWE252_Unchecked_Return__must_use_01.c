/* STATE B — a half-fix: the result is still discarded, just on a branch. A path drops the
   @must_use value, so it is STILL UNUSED_MUST_USE. */
/* CWE: 252 Unchecked Return Value */
// @must_use
int check_status(void);

void CWE252_Unchecked_Return__must_use_01_bad(int c)
{
    /* POTENTIAL FLAW: the result is dropped on the c-path */
    if (c) { check_status(); }
}
