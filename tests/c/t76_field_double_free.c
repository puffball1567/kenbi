#include <stdlib.h>
typedef struct { char *buf; } box_t;
void f(box_t *b, int n) {
  b->buf = malloc(n);
  free(b->buf);
  free(b->buf);            // double free through the field path   //EXPECT DOUBLE_FREE
}
