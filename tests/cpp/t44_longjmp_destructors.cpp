#include <csetjmp>
#include <string>
#include <utility>
#include <array>
#include <vector>
#include <memory>
// A NON-LOCAL JUMP SKIPS DESTRUCTORS. Unlike a `throw`, `longjmp` runs nothing on its way out, and
// C++ makes the jump undefined behaviour when an object it leaves has a non-trivial destructor
// ([csetjmp.syn]). At a call that may longjmp, every such object in scope is reported:
// LONGJMP_SKIPS_DESTRUCTOR. Whether a destructor is trivial is clang's answer, not a guess, so
// `std::array<int, 3>` and `std::pair<int, int>` are not reported and `std::string` is. An object
// whose scope closed before the call, one declared after it, and one whose initializer is the
// jumping call (it was never constructed) are not in scope there.

static std::jmp_buf env;

struct Guard { ~Guard() {} };
struct Pod { int a; double b; };

// @longjmps
void fail(int c) { if (c) std::longjmp(env, 1); }

// @longjmps
int fail_value(int c) { fail(c); return c; }

// @longjmps
void skips(int c) {
  std::string s = "x";
  Guard g;
  std::array<int, 3> arr{};
  std::pair<int, int> pr{1, 2};
  Pod pod{};
  int n = c;
  fail(n);                                      //EXPECT LONGJMP_SKIPS_DESTRUCTOR LONGJMP_SKIPS_DESTRUCTOR
}

// @longjmps
void scopes(int c) {
  {
    std::vector<int> closed;
  }
  int got = fail_value(c);
  std::vector<int> later;
  (void)got;
}

// @longjmps
void initializer_is_the_jump(int c) {
  std::string s(fail_value(c), 'x');
}

// @longjmps
void by_value_parameter(std::string name, int c) {
  fail(c);                                      //EXPECT LONGJMP_SKIPS_DESTRUCTOR
}

// @longjmps
void array_of_objects(int c) {
  Guard gs[2];
  fail(c);                                      //EXPECT LONGJMP_SKIPS_DESTRUCTOR
}

// an RAII owner is one of those objects: reported once, as the destructor it skips (not also as a leak)
// @longjmps
void smart_pointer(int c) {
  std::unique_ptr<int> up(new int(1));
  fail(c);                                      //EXPECT LONGJMP_SKIPS_DESTRUCTOR
}

// a jump from a lambda handed to another function: kenbi does not follow when it runs — refused
template <class F> void run(F f) { f(); }
// @longjmps
void in_lambda(int c) {
  run([c] { fail(c); });                        //EXPECT UNSUPPORTED_CONSTRUCT
}
// @kenbi
