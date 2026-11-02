#include <cstdint>
#include <memory>
#include <new>
// `@raii` owner types as PARAMETERS — the other half of the KIR pipeline: every sink KIR emits
// receives the owner by value (OwnershipConsume: `std::move` at the callsite, the callee owns it)
// or by reference (OwnershipBorrow / BorrowMut: the caller still owns it). The parameter's
// binding form declares the contract:
//   T v          by value      -> the callee OWNS it (moved in); its destructor releases it
//   T&& v        rvalue ref    -> the callee may take it; treated as owned
//   T& / const T& v            -> a BORROW: the caller owns it, so moving it away is BORROW_MOVED
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

// by value: the callee owns it — released by its destructor at exit -> clean
static std::uint32_t consume(kir_owned_scalar<std::uint32_t> v) { return v.read(); }

// by value, moved on, then used inside the callee -> use-after-move
static std::uint32_t consume_then_use(kir_owned_scalar<std::uint32_t> v) {
  std::uint32_t a = consume(std::move(v));
  return a + v.read();   //EXPECT USE_AFTER_MOVE
}

// T&: a BORROW — the caller still owns it; moving it away is stealing a borrow
static std::uint32_t steal_borrow(kir_owned_scalar<std::uint32_t>& v) {
  return consume(std::move(v));   //EXPECT BORROW_MOVED
}

// const T&: reading a borrow is fine -> clean
static std::uint32_t peek(const kir_owned_scalar<std::uint32_t>& v) { return v.read(); }

// T&&: the callee may take it — moving it on is fine, leaving it is fine -> clean
static std::uint32_t take_rref(kir_owned_scalar<std::uint32_t>&& v) { return consume(std::move(v)); }
