#include <cstdint>
#include <memory>
#include <new>
// OWNERS LIVING IN STRUCT FIELDS. A struct that holds an owner (an `@raii` class or unique_ptr)
// as a member holds that resource: a local / parameter of the struct carries one RAII origin
// per owner field (keyed as the field path `h->p`), the struct's destructor releases them all
// (never a leak), moving a field out — or moving the WHOLE struct — leaves it moved-from, and
// the library seam works through the field (`h.p.get()` / `h.p.release()`).
[[noreturn]] static void kir_trap() { __builtin_trap(); }

// @raii
template <typename T> class kir_owned_scalar {
  std::unique_ptr<T> storage;
public:
  explicit kir_owned_scalar(T value) noexcept : storage(new (std::nothrow) T(value)) {
    if (!storage) kir_trap();
  }
  kir_owned_scalar(const kir_owned_scalar&) = delete;
  kir_owned_scalar& operator=(const kir_owned_scalar&) = delete;
  kir_owned_scalar(kir_owned_scalar&&) noexcept = default;
  kir_owned_scalar& operator=(kir_owned_scalar&&) noexcept = default;
  ~kir_owned_scalar() = default;
  T read() const noexcept { if (!storage) kir_trap(); return *storage; }
};

// @frees(p)
void lib_take(int *p);

struct Holder {
  std::unique_ptr<int> p;
  kir_owned_scalar<std::uint32_t> v;
  Holder() : p(new int(1)), v(2) {}
};

// moving an owner field out, then dereferencing it -> use-after-move (through the field path)
static int field_use_after_move() {
  Holder h;
  std::unique_ptr<int> q = std::move(h.p);
  return *q + *h.p;   //EXPECT USE_AFTER_MOVE
}

// still owned at scope exit: the struct's destructor releases every owner field -> no LEAK
static int field_scope_ok() {
  Holder h;
  return *h.p + (int)h.v.read();
}

// the seam through a field: a .get() borrow handed to a freeing library
static void field_get_to_freer() {
  Holder h;
  lib_take(h.p.get());   //EXPECT FREE_INTERIOR
}

// moving the WHOLE struct moves every owner field out of the source
static int whole_struct_move() {
  Holder h;
  Holder g = std::move(h);
  return *g.p + *h.p;   //EXPECT USE_AFTER_MOVE
}

// a struct taken by REFERENCE: its owner fields are borrows — moving one away steals it
static void steal_field_from_borrow(Holder& h) {
  std::unique_ptr<int> q = std::move(h.p);   //EXPECT BORROW_MOVED
  (void)q;
}

// a struct taken by VALUE: the callee owns every field -> clean
static int own_struct_param(Holder h) { return *h.p; }
