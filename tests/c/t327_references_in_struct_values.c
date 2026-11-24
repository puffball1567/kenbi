#include <stdlib.h>
// @refcheck file
/*
 * STRUCTS THAT CARRY A POINTER. A slice, a cursor, a view: a struct with a pointer member can
 * refer into storage it does not own, and is followed like a pointer when it is. What a value
 * of such a type refers into depends on where it came from — the result of a function declared
 * `@returns_into(param)` refers into that parameter's storage, the result of a function that
 * declares nothing may refer into any of its pointer arguments, and a copy refers where the
 * original does. A struct with no pointer in it refers into nothing. A function that returns
 * such a struct built from a parameter must declare it (REF_RETURN_UNDECLARED), exactly as
 * for a pointer.
 */

struct Buf { char *data; unsigned len, cap; };
struct Slice { char *ptr; unsigned len; };
struct Stat { unsigned len, cap; };

// @invalidates(b)
void buf_append(struct Buf *b, const char *s);
// @returns_into(b)
// @invalidates()
struct Slice buf_slice(struct Buf *b);
// @invalidates()
struct Slice buf_view(struct Buf *b);
// @invalidates()
struct Stat buf_stat(struct Buf *b);

// a slice of the buffer, used after the buffer may have moved
void slice_used(struct Buf *b) {
  struct Slice s = buf_slice(b);
  buf_append(b, "abc");
  s.ptr[0] = 'x';                                 //EXPECT REF_INVALIDATED
}

// from a function that does not say what its result refers into
void slice_from_undeclared(struct Buf *b) {
  struct Slice s = buf_view(b);
  buf_append(b, "abc");
  s.ptr[0] = 'x';                                 //EXPECT REF_UNPROVEN
}

// a copy refers where the original does
void slice_copied(struct Buf *b) {
  struct Slice s = buf_slice(b);
  struct Slice t = s;
  buf_append(b, "abc");
  t.ptr[0] = 'x';                                 //EXPECT REF_INVALIDATED
}

// a struct of plain values refers into nothing
void plain_values(struct Buf *b) {
  struct Stat st = buf_stat(b);
  buf_append(b, "abc");
  unsigned n = st.len;
  (void)n;
}

// taken after the call
void slice_taken_after(struct Buf *b) {
  buf_append(b, "abc");
  struct Slice s = buf_slice(b);
  s.ptr[0] = 'x';
}

// a function that builds a slice of its parameter and does not declare it
struct Slice make_undeclared(struct Buf *b) {
  struct Slice s = { b->data, b->len };
  return s;                                       //EXPECT REF_RETURN_UNDECLARED
}

// ... as a compound literal
struct Slice make_literal(struct Buf *b) {
  return (struct Slice){ b->data, b->len };       //EXPECT REF_RETURN_UNDECLARED
}

// declared
// @returns_into(b)
struct Slice make_declared(struct Buf *b) {
  struct Slice s;
  s.ptr = b->data;
  s.len = b->len;
  return s;
}

// plain values taken from the parameter are not a reference into it
struct Stat make_stat(struct Buf *b) {
  struct Stat st = { b->len, b->cap };
  return st;
}
