// @kenbi
/* STATE B — honestly annotated: each `sink(p)` @moves the buffer (ownership transfers). Moving it
   a SECOND time transfers a value that is already gone — the reason converges to DOUBLE_MOVE. */
/* CWE: 672 Operation on a Resource after Release (moved twice) */
#include <stdlib.h>
void sink(void *p);
void CWE672_Double_Move__move_twice_02_bad(int n) {
    /* @mem demo::buf { free: free, owner: p } */
    char *p = malloc(n);
    if (!p) return;
    sink(p);   // @move demo::buf
    sink(p);   // @move demo::buf
}
