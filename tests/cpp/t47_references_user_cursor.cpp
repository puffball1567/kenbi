// @refcheck file
#include <vector>
/*
 * A CURSOR TYPE OF THE PROGRAM'S OWN. A class with a pointer member is followed like the
 * iterators of the standard library: a cursor obtained from a container refers into the
 * container's storage, and using it after the container may have reallocated is reported.
 * The type needs no declaration — what a value refers into follows from where it was
 * obtained. Its methods are functions of the program like any other: one that declares
 * `@invalidates()` reallocates nothing, one that declares nothing may.
 */

class Row {
 public:
  explicit Row(int *at) : at_(at) {}
  int &value() const { return *at_; }
  // @invalidates()
  void next() { ++at_; }
  void reset_somehow();
 private:
  int *at_;
};

class Table {
 public:
  Row first() { return Row(&cells_[0]); }
  // @invalidates(this)
  void grow() { cells_.push_back(0); }
  // @invalidates()
  unsigned size() const { return (unsigned)cells_.size(); }
 private:
  std::vector<int> cells_;
};

// the cursor, used after the table may have reallocated
void cursor_used(Table &t) {
  Row r = t.first();
  t.grow();
  r.value() = 1;                                  //EXPECT REF_INVALIDATED
}

// a copy of the cursor
void cursor_copied(Table &t) {
  Row r = t.first();
  Row s = r;
  t.grow();
  s.value() = 1;                                  //EXPECT REF_INVALIDATED
}

// stepping the cursor, and asking the table its size, are declared to reallocate nothing
void cursor_stepped(Table &t) {
  Row r = t.first();
  r.next();
  (void)t.size();
  r.value() = 1;
}

// a method of the cursor that declares nothing
void cursor_undeclared_method(Table &t) {
  Row r = t.first();
  r.reset_somehow();
  r.value() = 1;                                  //EXPECT REF_UNPROVEN
}

// taken after the call
void cursor_taken_after(Table &t) {
  t.grow();
  Row r = t.first();
  r.value() = 1;
}
