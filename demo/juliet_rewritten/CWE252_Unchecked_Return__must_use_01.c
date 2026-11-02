/* STATE C — the result is captured and returned to the caller (inspected, not discarded). GREEN. */
/* CWE: 252 Unchecked Return Value — fixed by using the result. */
// @must_use
int check_status(void);

int CWE252_Unchecked_Return__must_use_01_fixed(void)
{
    int r = check_status();   /* FIXED: the result is used */
    return r;
}
