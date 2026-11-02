#include <cstdlib>
#include <memory>
#include <new>
// A MOVE BETWEEN OWNERS KEEPS THE RESOURCE. `b = std::move(a)` hands a's resource to b: a borrow
// taken from `a` before the move still points at a live resource (now b's), and only the HANDLE
// `a` is moved-from. Likewise `unique_ptr<T> up(p)` / `up.reset(p)` take the raw `p` — which then
// stays a valid BORROW of the owner (`*p` fine, `free(p)` is FREE_INTERIOR). `up.reset()` releases
// the owner's current resource, so a borrow taken from it before dangles.

// @frees(p)
void lib_take(int *p) noexcept;
// @borrows(p)
void lib_read(int *p) noexcept;

struct Holder {
  std::unique_ptr<int> p;
  Holder() : p(new (std::nothrow) int(1)) {}
};

// a borrow taken from `a` survives the move: the resource lives on in `b` -> clean
int borrow_survives_move() {
  std::unique_ptr<int> a(new (std::nothrow) int(1));
  int *q = a.get();
  std::unique_ptr<int> b = std::move(a);
  lib_read(q);
  return *q + *b;
}

// ... but the moved-from HANDLE is not usable
int handle_after_move() {
  std::unique_ptr<int> a(new (std::nothrow) int(1));
  std::unique_ptr<int> b = std::move(a);
  return *a + *b;   //EXPECT USE_AFTER_MOVE
}

// ... nor its seam
void seam_after_move() {
  std::unique_ptr<int> a(new (std::nothrow) int(1));
  std::unique_ptr<int> b = std::move(a);
  lib_read(a.get());   //EXPECT USE_AFTER_MOVE
}

// ... nor can it be moved twice
void moved_twice() {
  std::unique_ptr<int> a(new (std::nothrow) int(1));
  std::unique_ptr<int> b = std::move(a);
  std::unique_ptr<int> c = std::move(a);   //EXPECT DOUBLE_MOVE
  (void)b; (void)c;
}

// the destination's borrow is the same resource: freeing it is still FREE_INTERIOR
void freer_through_destination() {
  std::unique_ptr<int> a(new (std::nothrow) int(1));
  std::unique_ptr<int> b = std::move(a);
  lib_take(b.get());   //EXPECT FREE_INTERIOR
}

// move-assignment between owners keeps the resource too
int move_assign_keeps() {
  std::unique_ptr<int> a(new (std::nothrow) int(1));
  std::unique_ptr<int> b;
  int *q = a.get();
  b = std::move(a);
  return *q + *b;
}

// a raw pointer handed to an owner stays a valid borrow of it
int raw_into_owner_ok() {
  /* @mem demo::buf { free: free, owner: p } */
  int *p = (int *)malloc(sizeof(int));
  std::unique_ptr<int, void (*)(void *)> up(p, free);
  return *p;
}

// ... but freeing it is freeing the owner's resource from the wrong side
void raw_into_owner_freed() {
  /* @mem demo::buf { free: free, owner: p } */
  int *p = (int *)malloc(sizeof(int));
  std::unique_ptr<int, void (*)(void *)> up(p, free);
  free(p);   //EXPECT FREE_INTERIOR
}

// reset releases the current resource: a borrow taken from it before dangles
int reset_dangles_borrow() {
  std::unique_ptr<int> up(new (std::nothrow) int(1));
  int *q = up.get();
  up.reset(new (std::nothrow) int(2));
  return *q;   //EXPECT USE_AFTER_FREE
}

// a struct of owners moved whole: a borrow of a field survives, the source's field handle does not
int struct_move_keeps() {
  Holder h;
  int *q = h.p.get();
  Holder g = std::move(h);
  lib_read(q);
  return *q + *g.p + *h.p;   //EXPECT USE_AFTER_MOVE
}
