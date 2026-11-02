// @spatial
/* STATE B — a bound is present but sized for the WRONG buffer: `idx < 1000` does not cover the
   256-element `table`. kenbi compares the check against the buffer's real size:
   INAPPROPRIATE_BOUND. */
/* CWE: 125 Out-of-bounds Read (fixed-size buffer, wrong-size bound) */
extern int table[256];

int CWE125_Out_of_Bounds_Read__fixed_array_06_bad(unsigned idx)
{
    /* POTENTIAL FLAW: 1000 > 256 — the bound does not cover table */
    if (idx < 1000)
        return table[idx];
    return 0;
}
