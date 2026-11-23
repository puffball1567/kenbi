// @refcheck
#include <stdlib.h>
#include <string.h>
// POINTERS HANDED BACK BY A FUNCTION. An accessor returns a pointer into the object it is
// given, and the caller must treat it like one it read out of the object itself.
// `@returns_into(param)` above a function declares that its result points into storage reached
// through `param`; `@returns_into()` that it points into none of its arguments. The result of
// a function that declares nothing may point into what any pointer argument holds: using it
// after that argument is invalidated is REF_UNPROVEN. The C library's searches and copies
// (`strchr`, `memcpy`, ...) are known to return a pointer into their argument's block. A
// function that returns a pointer into what a parameter holds must declare it
// (REF_RETURN_UNDECLARED), so that its callers can be checked.

struct Buf { char *data; unsigned len; };
struct Item { char *name; };

// @returns_into(b)
char *buf_data(struct Buf *b);
// @invalidates(b)
void buf_append(struct Buf *b, const char *s);
// @preserves(b)
void buf_fill(struct Buf *b, char c);
const char *item_name(const struct Item *it);
void item_reset(struct Item *it);
// @returns_into()
const char *version(const struct Item *it);

// the accessor's result, used after the buffer is reallocated
void declared(struct Buf *b) {
  char *p = buf_data(b);
  buf_append(b, "abc");
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// ... an offset of it
void offset_of_result(struct Buf *b) {
  char *p = buf_data(b) + 2;
  buf_append(b, "abc");
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// a function that declares nothing about its result
void undeclared_result(struct Item *it) {
  const char *n = item_name(it);
  item_reset(it);
  (void)n[0];                                     //EXPECT REF_UNPROVEN
}

// a search result, used after the block it points into is released
// @frees(s)
void search_then_free(char *s) {
  char *p = strchr(s, 'x');
  free(s);
  if (p) p[0] = 0;                                //EXPECT REF_INVALIDATED
}

// the buffer is left in place
void preserved(struct Buf *b) {
  char *p = buf_data(b);
  buf_fill(b, 'a');
  p[0] = 'x';
}

// nothing invalidates the argument while the result is in use
void not_invalidated(struct Item *it) {
  const char *n = item_name(it);
  (void)n[0];
}

// the result is declared to point into none of the arguments
void declared_none(struct Item *it) {
  const char *v = version(it);
  item_reset(it);
  (void)v[0];
}

// used before the release
// @frees(s)
void search_then_use(char *s) {
  char *p = strchr(s, 'x');
  if (p) p[0] = 0;
  free(s);
}

// an accessor that does not say what it returns
char *getter_undeclared(struct Buf *b) {
  return b->data;                                 //EXPECT REF_RETURN_UNDECLARED
}

// ... one that names the wrong parameter
// @returns_into(a)
char *getter_wrong(struct Buf *a, struct Buf *b) {
  (void)a;
  return b->data;                                 //EXPECT REF_RETURN_UNDECLARED
}

// ... through a local copy
char *skip_spaces(char *s) {
  char *q = s;
  while (*q == ' ') q++;
  return q;                                       //EXPECT REF_RETURN_UNDECLARED
}

// declared
// @returns_into(b)
char *getter_declared(struct Buf *b) {
  return b->data + 1;
}

// a value, and a fresh block, point into nothing the caller gave
unsigned length(struct Buf *b) {
  return b->len;
}
char *fresh(void) {
  return malloc(4);
}
