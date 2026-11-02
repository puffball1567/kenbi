// @spatial
/* STATE B — a bound is present but UNDERFLOW-UNSAFE on the limit side: `i <= n - 4` computes
   `n - 4`, which WRAPS to a huge value when n < 4 (unsigned), making the bound vacuous and
   admitting any i. kenbi judges the check unsound: INAPPROPRIATE_BOUND. It needs the
   companion `n >= 4`. */
/*
 * CWE: 125 Out-of-bounds Read (limit-underflow flavour)
 * BadSink : buf[i]/buf[i+3] guarded by the underflow-prone `i <= n - 4` (no `n >= 4` companion)
 */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__limit_underflow_03_bad(const unsigned char *buf, unsigned n, unsigned i)
{
    /* POTENTIAL FLAW: `n - 4` underflows when n < 4 -> bound vacuous */
    if (i <= n - 4)
        return buf[i] + buf[i + 3];
    return 0;
}
