// @spatial
/* STATE A — adopted, a look-ahead read buf[i]..buf[i+3] with NO bound. UNVALIDATED_INDEX. */
/*
 * CWE: 125 Out-of-bounds Read (limit-underflow flavour)
 * BadSink : buf[i] + buf[i+3] with no bound on i
 */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__limit_underflow_03_bad(const unsigned char *buf, unsigned n, unsigned i)
{
    /* POTENTIAL FLAW: no bound on i */
    return buf[i] + buf[i + 3];
}
