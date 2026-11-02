// @kenbi
/* STATE B — honestly annotated: the buffer is a declared resource and `process` only borrows it.
   Nothing says `process` cannot throw — if it unwinds, `delete p` is never reached and the raw
   owner is lost: the reason converges to LEAK_ON_THROW. */
/* CWE: 401 Memory Leak (on the exception path) */
#include <new>
// @borrows(p)
void process(int *p);
int CWE401_Memory_Leak__exception_path_01_bad(int n) {
    /* @mem demo::buf { free: delete, owner: p } */
    int *p = new (std::nothrow) int(n);
    if (!p) return -1;
    process(p);
    delete p;
    return 0;
}
