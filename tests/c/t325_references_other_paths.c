#include <stdlib.h>
#include <string.h>
// @refcheck file
/*
 * STORAGE A CALL IS NOT HANDED. A function can reallocate a buffer it reaches through a
 * global, so a pointer into a buffer is not safe across a call just because the buffer is not
 * among the arguments. A function of the program that declares nothing may do that to any
 * storage behind a pointer (REF_UNPROVEN). One that declares `@invalidates(global)` says which
 * storage it is — and a pointer the caller holds may point into that very object unless
 * something shows otherwise. A declaration is checked in the function's own body: releasing or
 * reallocating what it does not name is REF_NOT_PRESERVED. Storage that belongs to the calling
 * function alone — a local container, a local array — is out of every callee's reach, and
 * `@distinct(param, global)` declares that a parameter is not the object a global is or
 * points to.
 */

struct Buf { char *data; unsigned len, cap; };

static struct Buf *current;
static unsigned lines;

// declares nothing
void log_plain(const char *s);

// @invalidates(current)
void log_line(const char *s) {
  unsigned n = (unsigned)strlen(s);
  if (current->len + n > current->cap) {
    current->cap = (current->len + n) * 2;
    current->data = realloc(current->data, current->cap);
  }
  memcpy(current->data + current->len, s, n);
  current->len += n;
}

// @invalidates()
void count_line(void) {
  lines++;
}

// says it reallocates nothing, and does
// @invalidates()
void log_wrong(const char *s) {
  current->data = realloc(current->data, strlen(s));   //EXPECT REF_NOT_PRESERVED
}

// says it reallocates nothing, and calls a function that does
// @invalidates()
void log_through(const char *s) {
  log_line(s);                                    //EXPECT REF_NOT_PRESERVED
}

// ... or one that declares nothing
// @invalidates()
void log_unknown(const char *s) {
  log_plain(s);                                   //EXPECT REF_NOT_PRESERVED
}

// across a call that declares nothing
void across_undeclared(struct Buf *b) {
  char *p = b->data;
  log_plain("marking");
  p[0] = 'x';                                     //EXPECT REF_UNPROVEN
}

// across a call that reallocates what a global points to: `b` may be that object
void across_global(struct Buf *b) {
  char *p = b->data;
  log_line("marking");
  p[0] = 'x';                                     //EXPECT REF_UNPROVEN
}

// a pointer into the global's own buffer
void into_global(void) {
  char *p = current->data;
  log_line("marking");
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

// a plain pointer into a block the callee may reach as well
void plain_pointer(char *s) {
  char *end = s + strlen(s);
  log_plain("marking");
  end[0] = 0;                                     //EXPECT REF_UNPROVEN
}

// the function declares that `b` is not the object the global points to
// @distinct(b, current)
void across_global_distinct(struct Buf *b) {
  char *p = b->data;
  log_line("marking");
  p[0] = 'x';
}

// across a call declared to reallocate nothing
void across_declared(struct Buf *b) {
  char *p = b->data;
  count_line();
  p[0] = 'x';
}

// the pointer taken after the call
void taken_after(struct Buf *b) {
  log_line("marking");
  char *p = b->data;
  p[0] = 'x';
}

// a pointer into a local array: nothing outside this function reaches it
void local_storage(void) {
  char line[16];
  char *p = line + 1;
  log_plain("marking");
  p[0] = 'x';
}
