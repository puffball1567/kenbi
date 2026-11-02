#include <cstdlib>
#include <memory>
#include <new>
// shared_ptr is a built-in owner too (a COPY is a second live handle, a MOVE empties the
// source); make_unique / make_shared construct an owner — the deduced `auto` type IS the
// owner type; a custom deleter is still unique_ptr (template arguments are not the identity).

// @frees(p)
void lib_take(int *p) noexcept;
// @borrows(p)
void lib_read(int *p) noexcept;

// the deleter releases what it is handed — declared, like any other sink
// @frees(p)
struct FreeDeleter { void operator()(int *p) const noexcept { free(p); } };

// a copy keeps both handles live: using the source after a COPY is fine
int shared_copy_ok() {
  std::shared_ptr<int> a = std::make_shared<int>(1);
  std::shared_ptr<int> b = a;
  return *a + *b;
}

// a MOVE empties the source: using it is use-after-move
int shared_move_uaf() {
  std::shared_ptr<int> a = std::make_shared<int>(1);
  std::shared_ptr<int> b = std::move(a);
  return *b + *a;   //EXPECT USE_AFTER_MOVE
}

// the .get() borrow of a shared owner handed to a freeing library
void shared_get_to_freer() {
  auto sp = std::make_shared<int>(1);
  lib_take(sp.get());   //EXPECT FREE_INTERIOR
}

// make_unique with `auto`: an owner (never a leak), moved out then used
int make_unique_uaf() {
  auto up = std::make_unique<int>(1);
  auto other = std::move(up);
  return *up;   //EXPECT USE_AFTER_MOVE
}

// a custom deleter is still a unique_ptr owner: its .get() is a borrow
void deleter_get_to_freer() {
  std::unique_ptr<int, FreeDeleter> up((int *)malloc(sizeof(int)));
  lib_take(up.get());   //EXPECT FREE_INTERIOR
}

// ... and owned to scope exit -> clean
int deleter_scope_ok() {
  std::unique_ptr<int, FreeDeleter> up((int *)malloc(sizeof(int)));
  lib_read(up.get());
  return 0;
}

// a factory may throw (bad_alloc): a raw owner held across it is lost on that path
int raw_across_factory() {
  /* @mem demo::buf { free: delete, owner: p } */
  int *p = new (std::nothrow) int(1);
  auto sp = std::make_shared<int>(2);   //EXPECT LEAK_ON_THROW
  delete p;
  return *sp;
}
