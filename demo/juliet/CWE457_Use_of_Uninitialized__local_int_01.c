// @initcheck
/* STATE A — adopted for init checking (@initcheck), but the local `v` is READ with NO
   assignment on any path. kenbi default-reds the indeterminate read: USE_OF_UNINITIALIZED.
   (init is an opt-in axis, so state A carries the @initcheck adoption; the progression is
   no-init -> partial-init -> full-init.) */
/* CWE: 457 Use of Uninitialized Variable */
int CWE457_Use_of_Uninitialized__local_int_01_bad(void)
{
    int v;
    /* POTENTIAL FLAW: read before any assignment */
    return v;
}
