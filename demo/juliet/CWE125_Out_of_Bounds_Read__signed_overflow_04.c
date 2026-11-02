// @spatial
/* STATE A — adopted, a SIGNED index reaches the buffer with NO bound. UNVALIDATED_INDEX. */
/* CWE: 125 Out-of-bounds Read (signed overflow-guard flavour) */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__signed_overflow_04_bad(const char *buf, int n, int i)
{
    /* POTENTIAL FLAW: no bound on i */
    return buf[i];
}
