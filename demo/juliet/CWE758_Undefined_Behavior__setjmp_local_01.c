/* STATE A — `tries` is changed after the `setjmp` and read after a `longjmp` has come back to
   it. A non-volatile local changed in between has an indeterminate value there (C11
   7.13.2.1): the compiler may have kept it in a register the jump restored.
   SETJMP_CLOBBERED. */
/* CWE: 758 Reliance on Undefined, Unspecified, or Implementation-Defined Behavior */
#include <setjmp.h>

static jmp_buf retry_point;

// @longjmps_to(retry_point)
void attempt(int n);

// @kenbi
int CWE758_Undefined_Behavior__setjmp_local_01_bad(void)
{
    int tries = 0;
    if (setjmp(retry_point)) {
        /* POTENTIAL FLAW: `tries` was incremented after the setjmp and is read after the jump */
        if (tries > 3) return -1;
    }
    tries++;
    attempt(tries);
    return 0;
}
