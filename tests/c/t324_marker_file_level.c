#include <stdlib.h>
// AN OPT-IN MARKER FOR THE WHOLE FILE, WRITTEN OUT. A marker such as `// @refcheck` covers the
// function just below it when there is one within a few lines, and the whole file only when
// there is none — so at the top of a short file its reach depends on what happens to follow.
// `// @refcheck file` (and `@kenbi file`, `@spatial file`, `@threadsafe file`,
// `@initcheck file`, `@typecheck file`) says "the whole file" wherever it is written. Here the
// marker sits directly above the first function and still covers the second.

struct Buf { char *data; unsigned len, cap; };
// @invalidates(b)
void buf_append(struct Buf *b, const char *s);

// @refcheck file
void first(struct Buf *b) {
  char *p = b->data;
  buf_append(b, "abc");
  p[0] = 'x';                                     //EXPECT REF_INVALIDATED
}

void second(struct Buf *b) {
  char *p = b->data;
  buf_append(b, "abc");
  p[0] = 'y';                                     //EXPECT REF_INVALIDATED
}
