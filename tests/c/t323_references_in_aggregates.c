// @refcheck
#include <stdlib.h>
/*
 * REFERENCES KEPT IN A LOCAL STRUCT OR ARRAY. A pointer into a buffer does not have to sit in
 * a pointer variable: it is as often a member of a small struct beside its length, or one of
 * an array of row pointers. Under `@refcheck` each such member is followed like a variable of
 * its own — assigning it again replaces what it held, reading another member of the struct is
 * not a use of it, and using the struct as a whole is a use of every reference in it. The
 * elements of an array are followed together.
 */

struct Buf { char *data; unsigned len, cap; };
struct Slice { char *ptr; unsigned len; };

// @invalidates(b)
void buf_append(struct Buf *b, const char *s);
// @borrows(s)
void show(const struct Slice *s);

// the pointer member, used after the buffer may have moved
void member_used(struct Buf *b) {
  struct Slice s;
  s.ptr = b->data;
  s.len = b->len;
  buf_append(b, "abc");
  s.ptr[0] = 'x';                                 //EXPECT REF_INVALIDATED
}

// the struct handed on as a whole
void struct_passed(struct Buf *b) {
  struct Slice s;
  s.ptr = b->data;
  s.len = b->len;
  buf_append(b, "abc");
  show(&s);                                       //EXPECT REF_INVALIDATED
}

// a struct initialised with braces
void brace_initialised(struct Buf *b) {
  struct Slice s = { b->data, b->len };
  buf_append(b, "abc");
  s.ptr[0] = 'x';                                 //EXPECT REF_INVALIDATED
}

// an array of pointers, one of them into the buffer that moved
void row_pointers(struct Buf *a, struct Buf *b) {
  char *rows[2];
  rows[0] = a->data;
  rows[1] = b->data;
  buf_append(b, "abc");
  rows[1][0] = 'x';                               //EXPECT REF_INVALIDATED
}

// only the length is read after the call
void other_member_read(struct Buf *b) {
  struct Slice s;
  s.ptr = b->data;
  s.len = b->len;
  buf_append(b, "abc");
  unsigned n = s.len;
  (void)n;
}

// the member is assigned again after the call
void member_retaken(struct Buf *b) {
  struct Slice s;
  s.ptr = b->data;
  buf_append(b, "abc");
  s.ptr = b->data;
  s.ptr[0] = 'x';
}

// none of the buffers the rows point into is changed
void rows_untouched(struct Buf *a, struct Buf *b, struct Buf *c) {
  char *rows[2];
  rows[0] = a->data;
  rows[1] = b->data;
  buf_append(c, "abc");
  rows[0][0] = 'x';
}
