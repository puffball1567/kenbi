#include <stdlib.h>
typedef struct { char *buf; } box_t;
void use(char *q);
void f(box_t *b, int n) {
  b->buf = malloc(n);
  free(b->buf);
  use(b->buf);             // use after free through the field path   //EXPECT USE_AFTER_FREE
}
