// @kenbi
/* STATE C — the buffer is held by a unique_ptr: the unwinding itself releases it, so `process`
   may throw freely (alternatively, prove it cannot: declare it `noexcept` or vouch `@nothrow`).
   GREEN. */
/* CWE: 401 Memory Leak (on the exception path) — fixed with an RAII owner. */
#include <memory>
#include <new>
// @borrows(p)
void process(int *p);
int CWE401_Memory_Leak__exception_path_01_fixed(int n) {
    std::unique_ptr<int> p(new (std::nothrow) int(n));
    if (!p) return -1;
    process(p.get());
    return 0;
}
