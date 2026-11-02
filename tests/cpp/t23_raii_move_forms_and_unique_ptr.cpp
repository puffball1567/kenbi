#include <cstdint>
#include <memory>
#include <new>
// The other places KIR (and ordinary C++) put `std::move`: an owner INITIALISED from a move
// (`T y = std::move(x)`), an owner RE-ASSIGNED from a move (`y = std::move(x)` — in C++ that is
// an `operator=` call, not a BinaryOperator), and a move in a `return`. Plus std::unique_ptr as
// a BUILT-IN owner (no `@raii` needed): a fixed vocabulary item like malloc/free.
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

// `T y = std::move(x)`: the new owner takes x — reading x afterwards is a use-after-move
extern "C" std::uint32_t init_from_move() noexcept {
  kir_owned_scalar<std::uint32_t> x(1);
  kir_owned_scalar<std::uint32_t> y = std::move(x);
  return y.read() + x.read();   //EXPECT USE_AFTER_MOVE
}

// `y = std::move(x)` (operator=): same transfer; moving x a second time is a double move
extern "C" std::uint32_t assign_from_move() noexcept {
  kir_owned_scalar<std::uint32_t> x(1);
  kir_owned_scalar<std::uint32_t> y(2);
  y = std::move(x);
  y = std::move(x);   //EXPECT DOUBLE_MOVE
  return y.read();
}

// `return std::move(x)`: transferred to the caller; nothing left to release -> clean
static kir_owned_scalar<std::uint32_t> make_and_return() noexcept {
  kir_owned_scalar<std::uint32_t> x(3);
  return std::move(x);
}

// std::unique_ptr is a built-in owner: initialised from a move, the source is moved-from
static int unique_ptr_use_after_move() {
  std::unique_ptr<int> a(new int(1));
  std::unique_ptr<int> b = std::move(a);
  return *b + *a;   //EXPECT USE_AFTER_MOVE
}

// still owned at scope exit: the destructor releases it -> no LEAK
static int unique_ptr_scope_ok() {
  std::unique_ptr<int> c(new int(2));
  return *c;
}
