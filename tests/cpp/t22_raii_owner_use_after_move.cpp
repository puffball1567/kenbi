#include <cstdint>
#include <memory>
#include <new>
// RAII OWNER (`@raii`): the exact shape KIR emits for hosted owned scalars — a move-only class
// over std::unique_ptr, released by its destructor. Before `@raii` kenbi saw NO memory operation
// here (no malloc/free/new/delete on a tracked var): every function was "ok", including a
// use-after-move that the KIR runtime only catches by trapping. With `@raii` a local of the
// type is an owned origin: `std::move` moves it out, a later use is USE_AFTER_MOVE, a second
// move DOUBLE_MOVE — and reaching scope exit still-owned is NOT a leak (the dtor releases it).
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

static std::uint32_t consume(kir_owned_scalar<std::uint32_t> v) { return v.read(); }

extern "C" std::uint32_t use_after_move() noexcept {
  kir_owned_scalar<std::uint32_t> l0(7);
  std::uint32_t r = consume(std::move(l0));   // OwnershipConsume: moved out
  return r + l0.read();   // reading the moved-from owner   //EXPECT USE_AFTER_MOVE
}

extern "C" std::uint32_t double_move() noexcept {
  kir_owned_scalar<std::uint32_t> l0(7);
  std::uint32_t a = consume(std::move(l0));
  std::uint32_t b = consume(std::move(l0));   // moved out twice   //EXPECT DOUBLE_MOVE
  return a + b;
}

extern "C" std::uint32_t move_once_ok() noexcept {
  kir_owned_scalar<std::uint32_t> l0(7);
  return consume(std::move(l0));   // transferred once; nothing left to release -> clean
}

extern "C" std::uint32_t scope_release_ok() noexcept {
  kir_owned_scalar<std::uint32_t> l0(7);
  return l0.read();   // still owned at scope exit: the destructor releases it -> no LEAK
}
