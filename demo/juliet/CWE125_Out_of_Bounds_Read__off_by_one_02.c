// @spatial
/* STATE A — adopted, but the index reaches the buffer with NO bound. UNVALIDATED_INDEX. */
/*
 * CWE: 125 Out-of-bounds Read (off-by-one flavour)
 * BadSink : buf[i] with no bound on i
 */
// @counted_by(buf: n)
unsigned char CWE125_Out_of_Bounds_Read__off_by_one_02_bad(const unsigned char *buf, unsigned n, unsigned i)
{
    /* POTENTIAL FLAW: no bound on i */
    return buf[i];
}
