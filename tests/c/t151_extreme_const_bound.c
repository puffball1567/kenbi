// Regression: comparing / assigning against an EXTREME integer constant (INT64_MAX,
// 0x7fff…) must not overflow kenbi's bound-offset arithmetic. Real code (quickjs.c,
// numeric parsers) is full of such constants; kenbi used to crash (OverflowDefect) in
// boundWhenTrue / lowerScalarAssign. Now the unrepresentable c+1 upper bound is simply
// dropped (sound: trivial anyway) and analysis proceeds. No @spatial marker -> the
// bounds axis is off; this file asserts only that parsing/lowering does not crash and
// produces no findings.
#include <stdint.h>

int cmp_extreme(int64_t x) {
  if (x <= 9223372036854775807LL)   // INT64_MAX on the limit side: limOff - varOff + 1
    return 1;
  if (x < 0x7fffffffffffffffLL)
    return 2;
  if (9223372036854775807LL > x)    // variable on the larger side (lower-bound path)
    return 3;
  if (x != 0x7fffffffffffffffLL)    // disequality path (neqBound)
    return 4;
  return 0;
}

int assign_extreme(void) {
  int64_t a = 9223372036854775807LL;   // const assign: c + 1 upper bound
  int64_t b = a & 0x7fffffffffffffffLL; // mask with an extreme constant: mask + 1
  return (int)(a + b);
}
