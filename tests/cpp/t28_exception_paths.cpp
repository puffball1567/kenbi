#include <new>
#include <memory>
// EXCEPTION PATHS (C++). A `throw` leaves the function by unwinding, and so may any call to a
// callee without a nothrow guarantee — `noexcept` / `throw()` / a literally-true noexcept(expr)
// / glibc `__THROW` / the `@nothrow` vouch — and a plain `new` (bad_alloc). An RAII owner is
// released by the unwinding itself; a RAW owner still held at such a point is lost on that path.

void may_fail(int x);              // no specification: may throw
void safe_fn(int x) noexcept;
// @nothrow
// @borrows(p)
void logged(int *p);               // vouched: never throws (a C-style helper compiled as C++)
// @borrows(p)
void peek(int *p) noexcept;
// @frees(p)
void take(int *p) noexcept;

// an explicit throw between the allocation and the release abandons the raw owner
int throw_leaks(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);   //EXPECT LEAK
  if (x < 0) throw 1;
  delete p;
  return 0;
}

// a call without a nothrow guarantee: on its throwing path the raw owner is never released
int call_may_throw(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  may_fail(x);                          //EXPECT LEAK_ON_THROW
  delete p;
  return 0;
}

// noexcept callees, a @nothrow vouch, a declared borrow, a declared sink: no unwinding exit
int nothrow_ok(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  safe_fn(x);
  logged(p);
  peek(p);
  take(p);
  return 0;
}

// an RAII owner is released by unwinding — a may-throw call across it is fine
int raii_ok(int x) {
  std::unique_ptr<int> up(new (std::nothrow) int(1));
  may_fail(x);
  return *up;
}

// a plain `new` may throw bad_alloc: the FIRST raw owner is lost if the second allocation throws
int new_may_throw() {
  /* @mem demo::a { free: delete, owner: a } */
  int *a = new (std::nothrow) int(1);
  /* @mem demo::b { free: delete, owner: b } */
  int *b = new int(2);                  //EXPECT LEAK_ON_THROW
  delete a;
  delete b;
  return 0;
}

// a `@frees` obligation still held when a callee may throw: the contract breaks on that path
// @frees(p)
int contract_on_throw(int *p, int x) {
  may_fail(x);                          //EXPECT LEAK_ON_THROW
  delete p;
  return 0;
}

// a may-throw call inside a `try` lands in the handler — no raw owner held, nothing to report
// (the try / catch model itself: t29)
int try_modelled(int x) {
  try { may_fail(x); } catch (...) { return -1; }
  return 0;
}
