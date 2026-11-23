/* STATE C — the counter is `volatile`: every change is written to memory, so the value read
   after the jump is the one last stored. GREEN. */
/* CWE: 758 — fixed by declaring the local `volatile`. */
#include <setjmp.h>

static jmp_buf retry_point;

// @longjmps_to(retry_point)
void attempt(int n);

// @kenbi
int CWE758_Undefined_Behavior__setjmp_local_01_fixed(void)
{
    volatile int tries = 0;   /* FIXED: volatile */
    if (setjmp(retry_point)) {
        if (tries > 3) return -1;
    }
    tries++;
    attempt(tries);
    return 0;
}
