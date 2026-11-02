#include <stdlib.h>
typedef struct { char *buf; } box_t;
void use(char *q);
void f(box_t *b, int n) {
  b->buf = malloc(n);
  use(b->buf);
  free(b->buf);            // alloc, use, free once through the field -> clean
}
