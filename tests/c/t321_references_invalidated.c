// @refcheck
#include <stdlib.h>
#include <string.h>
// REFERENCES INTO STORAGE ANOTHER OBJECT MANAGES. A pointer taken out of a buffer stays valid
// only while the buffer stays where it is. Under `@refcheck`, a local that holds such a
// pointer is followed along each path, and using it after a call that may have reallocated or
// released the storage is reported: REF_INVALIDATED when the call is declared or known to
// (`@invalidates(param)`, `realloc`, `free`), REF_UNPROVEN when it is handed a writable
// pointer to the object and declares nothing. `@preserves(param)` declares that a function
// reallocates and releases nothing reached through the parameter, and its body is checked
// against that (REF_NOT_PRESERVED). A `const` parameter needs no declaration.

struct Buf { char *data; unsigned len, cap; };
struct Buf g_buf;

// @invalidates(b)
void buf_append(struct Buf *b, const char *s);
// @preserves(b)
void buf_fill(struct Buf *b, char c);
void buf_touch(struct Buf *b);
unsigned buf_len(const struct Buf *b);
void helper(void);
// @preserves(g_buf)
void logs(const char *s);
void grow(char **pp);

// a pointer into the buffer, used after a call declared to reallocate it
void declared(struct Buf *b) {
  char *p = b->data;
  buf_append(b, "abc");
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// ... after a call that says nothing either way
void undeclared(struct Buf *b) {
  char *p = b->data;
  buf_touch(b);
  p[0] = 'x';                                     //EXPECT REF_UNPROVEN
}

// ... after the block itself was reallocated here
void reallocated_here(struct Buf *b) {
  char *p = b->data + 1;
  b->data = realloc(b->data, 64);
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// on one of two paths
void one_branch(struct Buf *b, int c) {
  char *p = b->data;
  if (c) buf_append(b, "abc");
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// by the previous iteration of a loop
void in_loop(struct Buf *b, int n) {
  char *p = b->data;
  for (int i = 0; i < n; i++) {
    p[i] = 'x';                                   //EXPECT REF_INVALIDATED
    buf_append(b, "abc");
  }
}

// a buffer held in a local struct
void local_struct(void) {
  struct Buf s = {0};
  char *p = s.data;
  buf_append(&s, "abc");
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// a plain pointer whose address is handed out
void plain_pointer(char *buf) {
  char *p = buf;
  grow(&buf);
  p[0] = 'x';                                     //EXPECT REF_UNPROVEN
}

// a buffer reached from a global: any function of the program can reach it too
void from_global(void) {
  char *p = g_buf.data;
  helper();
  p[0] = 'x';                                     //EXPECT REF_UNPROVEN
}

// a copy of the pointer is as invalid as the pointer
void copy_of_copy(struct Buf *b) {
  char *p = b->data;
  char *q = p + 2;
  buf_append(b, "abc");
  q[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// calls that leave the buffer in place: declared, `const`, the C library
void preserved(struct Buf *b) {
  char *p = b->data;
  buf_fill(b, 'a');
  (void)buf_len(b);
  memset(b->data, 0, 4);
  p[0] = 'x';
}

// the pointer taken again after the call
void retaken(struct Buf *b) {
  char *p = b->data;
  buf_append(b, "abc");
  p = b->data;
  p[0] = 'x';
}

// a call on a different object
void other_object(struct Buf *a, struct Buf *b) {
  char *p = a->data;
  buf_append(b, "abc");
  p[0] = 'x';
}

// a function that declares it leaves the global in place
void global_preserved(void) {
  char *p = g_buf.data;
  logs("step");
  p[0] = 'x';
}

// the declaration holds: only the contents and the length change
// @preserves(b)
void keeps_its_word(struct Buf *b) {
  b->len = 0;
  buf_fill(b, 'z');
}

// ... it does not: the block is reallocated
// @preserves(b)
void reallocates(struct Buf *b) {
  b->data = realloc(b->data, 128);                //EXPECT REF_NOT_PRESERVED
}

// ... or handed, through a local copy, to a function that declares nothing
// @preserves(b)
void passes_it_on(struct Buf *b) {
  struct Buf *c = b;
  buf_touch(c);                                   //EXPECT REF_NOT_PRESERVED
}
