// @kenbi
/* STATE C — the buffer is moved exactly once; nothing touches it after the transfer. GREEN. */
/* CWE: 672 Operation on a Resource after Release — fixed by moving once. */
#include <stdlib.h>
void sink(void *p);
void CWE672_Double_Move__move_twice_02_fixed(int n) {
    /* @mem demo::buf { free: free, owner: p } */
    char *p = malloc(n);
    if (!p) return;
    sink(p);   // @move demo::buf
}
