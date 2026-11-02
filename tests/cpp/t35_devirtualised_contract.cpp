#include <cstdlib>
#include <new>
// A VIRTUAL CALL DISPATCHES TO THE CLASS THE OBJECT WAS CONSTRUCTED AS — when that construction
// is in view (`Base *b = new Derived`, `const Base &b = Derived()`), the contract that applies
// is `Derived::method`'s. Contracts on member functions are keyed `Class::method`, so two
// classes' `take` never collide. A base pointer whose dynamic type is not in view (a parameter)
// stays uncontracted — default-red — never the most convenient override's contract.
// (The Juliet 81 / 82 shape.)

// @borrows(s)
void use(char *s) noexcept;

struct Base {
  virtual void take(char *p) const noexcept = 0;
  virtual ~Base() {}
};

struct Freer : Base {
  // @frees(p)
  void take(char *p) const noexcept override { free(p); }
};

struct Reader : Base {
  // @borrows(p)
  void take(char *p) const noexcept override { use(p); }
};

// dispatches to Freer::take, which frees: the second free is a double free
static void via_freer() {
  /* @mem t::a { free: free, owner: d } */
  char *d = (char *)malloc(8);
  /* @mem t::obj { free: delete, owner: b } */
  Base *b = new (std::nothrow) Freer;
  b->take(d);
  free(d);   //EXPECT DOUBLE_FREE
  delete b;
}

// dispatches to Reader::take, which only reads: never released -> leak
static void via_reader_leaks() {
  /* @mem t::b { free: free, owner: d } */
  char *d = (char *)malloc(8);   //EXPECT LEAK
  const Base &r = Reader();
  r.take(d);
}

// ... released after the reader -> clean
static void via_reader_ok() {
  /* @mem t::c { free: free, owner: d } */
  char *d = (char *)malloc(8);
  const Base &r = Reader();
  r.take(d);
  free(d);
}

// the dynamic type is not in view: no contract can be assumed
static void unknown_dispatch(const Base &r) {
  /* @mem t::d { free: free, owner: d } */
  char *d = (char *)malloc(8);
  r.take(d);   //EXPECT UNCONTRACTED_ESCAPE
  free(d);     //EXPECT POSSIBLE_DOUBLE_FREE
}
