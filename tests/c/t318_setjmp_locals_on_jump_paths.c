#include <setjmp.h>
#include <stdio.h>
// LOCALS ACROSS A LONGJMP, followed along the paths the jump takes. A non-volatile automatic
// local changed between the setjmp and the longjmp is indeterminate once the jump has returned
// (C11 7.13.2.1), and stays so until it is assigned again — wherever the use is: in the landing
// branch, or in the code after it when the branch falls through. A local that was not changed
// since the setjmp last ran, one assigned again before the use, and a volatile one are all
// determinate; a landing branch that leaves the function makes the code after it unreachable
// for the jump.

static jmp_buf env;

// @longjmps_to(env)
static void fail(void) { longjmp(env, 1); }

// the use is inside the landing branch
// @kenbi
int in_branch(void) {
  int tries = 0;
  if (setjmp(env)) {
    if (tries > 3) return -1;                     //EXPECT SETJMP_CLOBBERED
  }
  tries++;
  fail();
  return 0;
}

// the same use, after the landing branch has fallen through
// @kenbi
int after_branch(void) {
  int tries = 0;
  if (setjmp(env)) {
    puts("retry");
  }
  if (tries > 3) return -1;                       //EXPECT SETJMP_CLOBBERED
  tries++;
  fail();
  return 0;
}

// ... and after a `switch` on the setjmp that a landing case breaks out of
// @kenbi
int after_switch(void) {
  int n = 0;
  switch (setjmp(env)) {
  case 0:
    break;
  default:
    puts("retry");
    break;
  }
  if (n > 3) return -1;                           //EXPECT SETJMP_CLOBBERED
  n++;
  fail();
  return 0;
}

// an element of a local array is part of the array
// @kenbi
int array_element(void) {
  char seen[8];
  seen[0] = 0;
  if (setjmp(env)) {
    puts("retry");
  }
  if (seen[0] == 3) return -1;                    //EXPECT SETJMP_CLOBBERED
  seen[0]++;
  fail();
  return 0;
}

// the landing branch leaves the function: the jump never reaches the code after it
// @kenbi
int branch_leaves(void) {
  int n = 0;
  if (setjmp(env)) {
    return -1;
  }
  n++;
  fail();
  return n;
}

// assigned again where the jump lands, before any use
// @kenbi
int assigned_again(void) {
  int n = 0;
  if (setjmp(env)) {
    n = 0;
  }
  if (n > 3) return -1;
  n++;
  fail();
  return 0;
}

// not changed after the setjmp
// @kenbi
int unchanged(int k) {
  int n = k * 2;
  if (setjmp(env)) {
    puts("retry");
  }
  if (n > 3) return -1;
  fail();
  return 0;
}

// changed only before the setjmp ran again: each iteration's setjmp sees the stored value
// @kenbi
int changed_before_each_setjmp(int m) {
  int n = 0;
  for (int i = 0; i < m; i++) {
    n = i;
    if (setjmp(env)) {
      printf("%d\n", n);
      continue;
    }
    fail();
  }
  return 0;
}

// volatile: the stored value survives the jump
// @kenbi
int declared_volatile(void) {
  volatile int n = 0;
  if (setjmp(env)) {
    puts("retry");
  }
  if (n > 3) return -1;
  n++;
  fail();
  return 0;
}
