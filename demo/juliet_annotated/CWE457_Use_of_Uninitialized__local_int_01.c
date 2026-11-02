// @initcheck
/* STATE B — a half-fix: `v` is assigned on ONLY ONE branch, so a path still reaches the read
   with `v` unassigned. Definite-assignment is a MUST-property (assigned only if on EVERY path),
   so it is STILL USE_OF_UNINITIALIZED. You cannot half-initialise your way out. */
/* CWE: 457 Use of Uninitialized Variable */
int CWE457_Use_of_Uninitialized__local_int_01_bad(int c)
{
    int v;
    /* POTENTIAL FLAW: assigned on the c-path only */
    if (c) { v = 1; }
    return v;
}
