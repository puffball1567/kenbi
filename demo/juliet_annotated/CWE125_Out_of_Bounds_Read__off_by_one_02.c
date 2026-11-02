// @spatial
/* STATE B — a bound is present but OFF BY ONE: `i <= n` admits `i == n`, one past the last
   valid index (n-1) of an n-element buffer. kenbi judges the check too loose:
   INAPPROPRIATE_BOUND. A present check is not a correct check. */
/*
 * CWE: 125 Out-of-bounds Read (off-by-one flavour)
 * BadSink : buf[i] guarded by the off-by-one `i <= n`
 */
// @counted_by(buf: n)
unsigned char CWE125_Out_of_Bounds_Read__off_by_one_02_bad(const unsigned char *buf, unsigned n, unsigned i)
{
    /* POTENTIAL FLAW: `<=` admits i == n (one past the end) */
    if (i <= n)
        return buf[i];
    return 0;
}
