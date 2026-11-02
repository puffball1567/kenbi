/* STATE C — the returned pointer refers to STATIC storage, which outlives the call, so it does
   not dangle. GREEN. */
/* CWE: 562 Return of Stack Variable Address — fixed by using static storage. */
int *CWE562_Return_of_Stack_Address__local_01_fixed(void)
{
    static int x = 42;
    return &x;   /* FIXED: static storage outlives the frame */
}
