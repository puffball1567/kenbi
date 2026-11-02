// @spatial
/* STATE B — a guard is present (`i >= 0 && i + 4 <= n`) but its arithmetic `i + 4` can OVERFLOW
   for a SIGNED i near INT_MAX (undefined behaviour; it wraps to INT_MIN, a large negative that
   passes `<= n` yet indexes far out of range). Whether it overflows is an unverified property
   of an untrusted value, so kenbi does not credit it — INAPPROPRIATE_BOUND (option B). */
/* CWE: 125 Out-of-bounds Read (signed overflow-guard flavour) */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__signed_overflow_04_bad(const char *buf, int n, int i)
{
    /* POTENTIAL FLAW: signed `i + 4` overflow is UB, triggerable by an untrusted i */
    if (i >= 0 && i + 4 <= n)
        return buf[i];
    return 0;
}
