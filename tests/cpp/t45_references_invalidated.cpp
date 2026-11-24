// @refcheck
#include <list>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>
// REFERENCES INTO A CONTAINER. A pointer, a reference, an iterator or a view obtained from an
// object that manages its own storage — `&v[0]`, `v.front()`, `v.begin()`, `s.c_str()`,
// `up.get()`, a `string_view` of a string — is invalid once the object may have reallocated or
// released that storage. Under `@refcheck` its use after such a call is REF_INVALIDATED for
// the standard containers' own methods and for functions declared `@invalidates`, and
// REF_UNPROVEN for a call that takes the object by non-const reference and declares nothing.
// A range-`for` holds iterators of its own for as long as it runs.

struct Item { int id; std::string name; };
void fill(std::vector<int> &v);
// @invalidates()
int total(const std::vector<int> &v);

void element_pointer(std::vector<int> &v) {
  int *e = &v[0];
  v.push_back(1);
  *e = 0;                                         //EXPECT REF_INVALIDATED
}

void element_reference(std::vector<int> &v) {
  int &r = v.front();
  v.resize(100);
  r = 0;                                          //EXPECT REF_INVALIDATED
}

// erasing through the iterator the loop goes on to step
void iterator_erased(std::vector<int> &v) {
  for (auto it = v.begin(); it != v.end(); ++it) { //EXPECT REF_INVALIDATED
    if (*it == 0) v.erase(it);
  }
}

// changing the container a range-for is going over
void range_for_grows(std::vector<int> &v) {
  for (int x : v) {                               //EXPECT REF_INVALIDATED
    if (x == 0) v.push_back(1);
  }
}

void string_data(std::string &s) {
  const char *p = s.c_str();
  s += "tail";
  (void)p[0];                                     //EXPECT REF_INVALIDATED
}

void view_of_string(std::string &s) {
  std::string_view sv = s;
  s.clear();
  (void)sv.size();                                //EXPECT REF_INVALIDATED
}

void pointee_of_owner(std::unique_ptr<Item> &up) {
  Item *raw = up.get();
  up.reset();
  raw->id = 1;                                    //EXPECT REF_INVALIDATED
}

// a reference to a member of an element
void member_of_element(std::vector<Item> &items) {
  const std::string &n = items[0].name;
  items.emplace_back();
  (void)n.size();                                 //EXPECT REF_INVALIDATED
}

// handed to a function that takes it by non-const reference and declares nothing
void through_function(std::vector<int> &v) {
  int *e = v.data();
  fill(v);
  *e = 0;                                         //EXPECT REF_UNPROVEN
}

struct Pool {
  std::vector<int> cells;
  void grow();
  // another method of the same object, undeclared
  void use() {
    int *c = &cells[0];
    grow();
    *c = 1;                                       //EXPECT REF_UNPROVEN
  }
  // @preserves(this)
  void touch() { cells.push_back(1); }            //EXPECT REF_NOT_PRESERVED
};

// the position saved before the erase is invalid as well
void saved_next(std::vector<int> &v) {
  auto it = v.begin();
  while (it != v.end()) {
    if (*it == 0) {
      auto next = it + 1;
      v.erase(it);
      it = next;                                  //EXPECT REF_INVALIDATED
    } else {
      ++it;
    }
  }
}

// stepping an iterator changes nothing of what it refers into
void stepped_copy(std::vector<int> &v) {
  auto it = v.begin();
  auto second = it + 1;
  ++it;
  --it;
  (void)*second;
}

// the iterator the erase returns replaces the erased one
void iterator_erase_idiom(std::vector<int> &v) {
  for (auto it = v.begin(); it != v.end(); ) {
    if (*it == 0) it = v.erase(it);
    else ++it;
  }
}

// leaving the loop right after the change
void range_for_then_break(std::vector<int> &v) {
  for (int x : v) {
    if (x == 0) { v.push_back(1); break; }
  }
}

// a function declared to reallocate nothing, element writes and size queries move nothing
void reads_only(std::vector<int> &v) {
  int *e = v.data();
  (void)total(v);
  (void)v.size();
  v[1] = 3;
  *e = 0;
}

// node-based containers keep their elements in place on insertion
void node_based(std::list<int> &l, std::map<int, int> &m) {
  int &a = l.front();
  l.push_back(2);
  a = 1;
  int &b = m[1];
  m[2] = 5;
  b = 1;
}

// a copy of an element is not a reference into the container
void value_copy(std::vector<Item> &items) {
  std::string n = items[0].name;
  items.clear();
  (void)n.size();
}
