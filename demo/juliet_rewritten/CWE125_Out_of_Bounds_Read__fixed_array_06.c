// @spatial
/* STATE C — the bound matches the buffer size (`idx < 256`), covering the 256-element table.
   GREEN. */
/* CWE: 125 Out-of-bounds Read — fixed with a bound that matches the buffer size. */
extern int table[256];

int CWE125_Out_of_Bounds_Read__fixed_array_06_fixed(unsigned idx)
{
    /* FIXED: bound matches the 256-element buffer */
    if (idx < 256)
        return table[idx];
    return 0;
}
