/* STATE B — a half-fix: the counter is copied into a second local before the call, and the
   copy is read after the jump. The copy is changed after the `setjmp` and non-volatile too, so
   it is STILL SETJMP_CLOBBERED. */
/* CWE: 758 Reliance on Undefined, Unspecified, or Implementation-Defined Behavior */
#include <setjmp.h>

static jmp_buf retry_point;

// @longjmps_to(retry_point)
void attempt(int n);

// @kenbi
int CWE758_Undefined_Behavior__setjmp_local_01_bad(void)
{
    int tries = 0;
    int seen = 0;
    if (setjmp(retry_point)) {
        /* POTENTIAL FLAW: `seen` is as indeterminate as `tries` was */
        if (seen > 3) return -1;
    }
    tries++;
    seen = tries;
    attempt(tries);
    return 0;
}
