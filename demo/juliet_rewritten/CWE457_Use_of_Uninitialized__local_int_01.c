// @initcheck
/* STATE C — `v` is definitely assigned on EVERY path (both branches), so the read is always of
   a determinate value. GREEN. */
/* CWE: 457 Use of Uninitialized Variable — fixed by assigning on all paths. */
int CWE457_Use_of_Uninitialized__local_int_01_fixed(int c)
{
    int v;
    /* FIXED: assigned on both branches */
    if (c) { v = 1; } else { v = 2; }
    return v;
}
