#include <cstdlib>
#include <map>
#include <vector>
// A STANDARD CONTAINER OF RAW POINTERS RELEASES NOTHING. Putting an owned pointer into one
// (`push_back` / `insert` / `emplace_back` …) moves its obligation to the container's element
// slot; a LOCAL container still holding it at scope exit is a LEAK (the vector's destructor
// frees the pointers it holds — it does not). Reading an element back (`v[i]`, `v.front()`, a
// range-for variable) ALIASES that slot, so releasing it there discharges the obligation and a
// second release is a double free. Only the standard containers are treated this way; a user
// class keeps the ordinary uncontracted-escape treatment (its destructor may well delete them).

// @borrows(s)
void use(char *s) noexcept;

// pushed into a local vector and never taken out -> leak
static void pushed_and_dropped() {
  std::vector<char *> v;
  /* @mem t::a { free: free, owner: p } */
  char *p = (char *)malloc(8);   //EXPECT LEAK
  v.push_back(p);
}

// ... the `insert` form is the same store
static void inserted_and_dropped() {
  std::vector<char *> v;
  /* @mem t::b { free: free, owner: p } */
  char *p = (char *)malloc(8);   //EXPECT LEAK
  v.insert(v.end(), 1, p);
}

// read back by index and released -> clean
static void released_via_index() {
  std::vector<char *> v;
  /* @mem t::c { free: free, owner: p } */
  char *p = (char *)malloc(8);
  v.push_back(p);
  char *q = v[0];
  free(q);
}

// ... released twice through the two handles
static void released_twice() {
  std::vector<char *> v;
  /* @mem t::d { free: free, owner: p } */
  char *p = (char *)malloc(8);
  v.push_back(p);
  char *q = v[0];
  free(q);
  free(p);   //EXPECT DOUBLE_FREE
}

// the idiomatic cleanup loop discharges it
static void released_in_range_for() {
  std::vector<char *> v;
  /* @mem t::e { free: free, owner: p } */
  char *p = (char *)malloc(8);
  v.push_back(p);
  for (char *q : v) {
    free(q);
  }
}

// a read-only loop leaves it owned -> leak
static void read_in_range_for() {
  std::vector<char *> v;
  /* @mem t::f { free: free, owner: p } */
  char *p = (char *)malloc(8);   //EXPECT LEAK
  v.push_back(p);
  for (char *q : v) {
    use(q);
  }
}

// an associative container takes it through `m[k] = p` — and frees nothing either
static void map_store_dropped() {
  std::map<int, char *> m;
  /* @mem t::g { free: free, owner: p } */
  char *p = (char *)malloc(8);   //EXPECT LEAK
  m[0] = p;
}

// ... read back and released -> clean
static void map_store_released() {
  std::map<int, char *> m;
  /* @mem t::h { free: free, owner: p } */
  char *p = (char *)malloc(8);
  m[0] = p;
  char *q = m[0];
  free(q);
}
