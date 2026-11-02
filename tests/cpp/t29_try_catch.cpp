#include <new>
#include <memory>
// TRY / CATCH. Every unwinding exit inside a `try` body — a `throw`, a call that may throw —
// lands in the handlers instead of leaving the function; the handlers start from the JOIN of
// those exits (may-set). Without a `catch (...)` the joined state also propagates out of the
// try (to an enclosing frame, or out of the function — where a raw owner still held leaks).

void may_fail(int x);              // no specification: may throw

// the handler releases the raw owner on the unwinding path and re-throws -> clean
int catch_releases(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  try { may_fail(x); } catch (...) { delete p; throw; }
  delete p;
  return 0;
}

// the handler forgets the owner and returns: the unwinding path leaks it
int catch_forgets(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);   //EXPECT LEAK
  try { may_fail(x); } catch (...) { return -1; }
  delete p;
  return 0;
}

// a typed handler does not catch everything: the propagating path still loses the owner
int typed_catch_propagates(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);   //EXPECT LEAK
  try { may_fail(x); } catch (std::bad_alloc &) { delete p; throw; }
  delete p;
  return 0;
}

// a throw inside the try lands in the handler, not at the function exit: release there -> clean.
// A literal `throw e` carries e's type: the handler naming EXACTLY that type consumes it
int throw_in_try(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  try { if (x < 0) throw 1; } catch (int) { delete p; return -1; }
  delete p;
  return 0;
}

// ... a const-reference handler of the same type matches too
int throw_ref_match(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  try { if (x < 0) throw std::bad_alloc(); } catch (const std::bad_alloc &e) { delete p; return -1; }
  delete p;
  return 0;
}

// ... but only an EXACT type: `throw 1` is an int, `catch (long)` does not take it — the
// exception propagates out of the function with the owner still held (C++ converts nothing here)
int throw_type_mismatch(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);   //EXPECT LEAK
  try { if (x < 0) throw 1; } catch (long) { delete p; return -1; }
  delete p;
  return 0;
}

// a base-class handler is NOT matched either (no hierarchy reasoning — declared exact types
// only): the derived exception propagates, red on that path
struct AppError : std::exception {};
int throw_base_catch(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);   //EXPECT LEAK
  try { if (x < 0) throw AppError(); } catch (const std::exception &e) { delete p; return -1; }
  delete p;
  return 0;
}

// the body released it, then a later call may throw: the handler's release is a double free
int handler_double_free(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  try { delete p; may_fail(x); } catch (...) { delete p; }   //EXPECT DOUBLE_FREE
  return 0;
}

// a try nested in a branch is modelled at any depth
int nested_try(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  if (x) {
    try { may_fail(x); } catch (...) { delete p; return -1; }
  }
  delete p;
  return 0;
}

// an RAII owner needs nothing from the handler
int raii_try(int x) {
  std::unique_ptr<int> up(new (std::nothrow) int(1));
  try { may_fail(x); } catch (...) { return -1; }
  return *up;
}

// nothing inside the body can throw: the handlers are unreachable and report nothing
int dead_handler(int x) {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  delete p;
  try { x++; } catch (...) { delete p; }
  return x;
}
