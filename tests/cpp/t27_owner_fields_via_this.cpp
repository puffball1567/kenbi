#include <memory>
// OWNER FIELDS INSIDE THE CLASS'S OWN MEMBER FUNCTIONS — `p` / `this->p`. A binding wrapper
// (`struct Conn { std::unique_ptr<X> x; ... }`) manages its owner from its methods; those
// accesses have no variable base, only `this`. Every method of a struct that holds owner
// fields enters owning each field (keyed `this::field`, released by the destructor — never a
// leak), so moving one out and using it, or handing its borrow to a freer, is checked here too.

// @frees(p)
void lib_take(int *p);

struct Holder {
  std::unique_ptr<int> p;
  Holder() : p(new int(1)) {}

  // implicit `this`: moving the field out, then dereferencing it -> use-after-move
  int take_then_use() {
    std::unique_ptr<int> q = std::move(p);
    return *q + *p;   //EXPECT USE_AFTER_MOVE
  }

  // explicit `this->`
  int take_explicit() {
    std::unique_ptr<int> q = std::move(this->p);
    return *this->p + *q;   //EXPECT USE_AFTER_MOVE
  }

  // reading the field is fine; the destructor releases it -> clean
  int peek() const { return *p; }

  // the seam through `this`: the field's borrow handed to a freeing library
  void give_to_freer() {
    lib_take(p.get());   //EXPECT FREE_INTERIOR
  }

  int take_out_of_line();
};

// an out-of-line member definition sees the same `this::p`
int Holder::take_out_of_line() {
  std::unique_ptr<int> q = std::move(p);
  return *p;   //EXPECT USE_AFTER_MOVE
}
