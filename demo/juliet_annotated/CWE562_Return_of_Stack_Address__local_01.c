/* STATE B — laundering the address through a pointer variable does not help: `p` still holds the
   address of the local `x`, so the returned pointer dangles. STILL DANGLING_RETURN. */
/* CWE: 562 Return of Stack Variable Address */
int *CWE562_Return_of_Stack_Address__local_01_bad(void)
{
    int x = 42;
    int *p = &x;
    /* POTENTIAL FLAW: p aliases &x — the return still dangles */
    return p;
}
