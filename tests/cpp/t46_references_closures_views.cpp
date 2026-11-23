// @refcheck
#include <string>
#include <string_view>
#include <vector>
/*
 * CLOSURES AND VIEWS. A closure holds a copy of each pointer it captures by value, taken when
 * the closure is made, and reads one captured by reference when its body runs; its body runs
 * wherever the closure is used. A view built from its parts — `string_view(s.data(), n)` —
 * refers into what those parts point into.
 */

// a view built from a pointer and a length
void view_from_parts(std::string &s) {
  std::string_view sv(s.data(), s.size());
  s.append("tail");
  (void)sv.size();                                //EXPECT REF_INVALIDATED
}

// captured by value: the closure's copy is as old as the closure, whatever the variable holds now
void captured_by_value(std::vector<int> &v) {
  int *e = &v[0];
  auto f = [e] { *e = 1; };
  v.push_back(1);
  e = &v[0];
  f();                                            //EXPECT REF_INVALIDATED
  (void)e;
}

// captured by reference and not taken again before the call
void captured_by_reference_stale(std::vector<int> &v) {
  int *e = &v[0];
  auto f = [&] { *e = 1; };                       //EXPECT REF_INVALIDATED
  v.push_back(1);
  f();
}

// the closure is what changes the container
void closure_invalidates(std::vector<int> &v) {
  int *e = &v[0];
  auto grow = [&] { v.push_back(1); };
  grow();
  *e = 0;                                         //EXPECT REF_INVALIDATED
}

// the whole mistake is inside the closure
void inside_the_closure(std::vector<int> &v) {
  auto f = [&] {
    int *e = &v[0];
    v.push_back(1);
    *e = 0;                                       //EXPECT REF_INVALIDATED
  };
  f();
}

// captured by reference and taken again before the call
void captured_by_reference_retaken(std::vector<int> &v) {
  int *e = &v[0];
  auto f = [&] { *e = 1; };
  v.push_back(1);
  e = &v[0];
  f();
}

// a closure that only reads the container
void closure_reads(std::vector<int> &v) {
  int *e = &v[0];
  auto size = [&] { return v.size(); };
  (void)size();
  *e = 0;
}

// a closure that is made and never used runs nothing
void closure_unused(std::vector<int> &v) {
  int *e = &v[0];
  auto grow = [&] { v.push_back(1); };
  *e = 0;
}
