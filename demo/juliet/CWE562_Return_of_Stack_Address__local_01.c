/* STATE A — the function returns the address of a LOCAL, whose storage is gone once the frame
   is popped. kenbi default-reds it: DANGLING_RETURN. */
/* CWE: 562 Return of Stack Variable Address */
int *CWE562_Return_of_Stack_Address__local_01_bad(void)
{
    int x = 42;
    /* POTENTIAL FLAW: &x dangles after return */
    return &x;
}
