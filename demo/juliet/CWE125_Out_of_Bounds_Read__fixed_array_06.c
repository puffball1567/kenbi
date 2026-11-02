// @spatial
/* STATE A — adopted, a fixed 256-element global array is indexed with NO bound. UNVALIDATED. */
/* CWE: 125 Out-of-bounds Read (fixed-size buffer, wrong-size bound) */
extern int table[256];

int CWE125_Out_of_Bounds_Read__fixed_array_06_bad(unsigned idx)
{
    /* POTENTIAL FLAW: no bound on idx */
    return table[idx];
}
