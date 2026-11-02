/* STATE A — `check_status` is declared @must_use (its result must be inspected), but the caller
   DROPS the return value. kenbi default-reds the discarded result: UNUSED_MUST_USE.
   Progression: dropped -> conditionally dropped -> checked. */
/* CWE: 252 Unchecked Return Value */
// @must_use
int check_status(void);

void CWE252_Unchecked_Return__must_use_01_bad(void)
{
    /* POTENTIAL FLAW: the @must_use result is discarded */
    check_status();
}
