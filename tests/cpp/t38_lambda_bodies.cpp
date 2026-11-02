#include <cstdlib>
#include <functional>
// A LAMBDA BODY RUNS WHERE IT IS CALLED, not where it is written. Lowering it at the definition
// (the old behaviour) was wrong in both directions: it invented a release that had not happened
// yet — hiding the leak when the lambda was never called — and it counted only one, so calling a
// cleanup lambda twice reported nothing at all. The body is now stored at the definition and
// spliced at each call. A lambda used in any other way (handed to a callee, kept in a
// std::function) runs at a time kenbi cannot place, so one that allocates or releases is refused
// rather than silently ignored.

// @borrows(s)
void use(char *s) noexcept;
// @borrows(f)
void run_later(std::function<void()> f) noexcept;

// defined but never called: nothing releases it
static void never_called() {
  /* @mem t::a { free: free, owner: p } */
  char *p = (char *)malloc(8);   //EXPECT LEAK
  auto cleanup = [&] { free(p); };
  use(p);
}

// called once -> clean
static void called_once() {
  /* @mem t::b { free: free, owner: p } */
  char *p = (char *)malloc(8);
  auto cleanup = [&] { free(p); };
  cleanup();
}

// called twice -> the second release is a double free
static void called_twice() {
  /* @mem t::c { free: free, owner: p } */
  char *p = (char *)malloc(8);
  auto cleanup = [&] { free(p); };
  cleanup();
  cleanup();   //EXPECT DOUBLE_FREE
}

// an immediately-invoked lambda runs right there -> clean
static void immediately_invoked() {
  /* @mem t::d { free: free, owner: p } */
  char *p = (char *)malloc(8);
  [&] { free(p); }();
}

// handed to a callee: it runs at a time kenbi cannot place
static void handed_off() {
  /* @mem t::e { free: free, owner: p } */
  char *p = (char *)malloc(8);
  auto cleanup = [&] { free(p); };
  run_later(cleanup);   //EXPECT UNSUPPORTED_CONSTRUCT
  use(p);
  cleanup();
}

// a lambda that touches no memory is inert wherever it goes
static int inert_lambda(int n) {
  auto twice = [&] { return n * 2; };
  return twice();
}
