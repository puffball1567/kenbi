#include <stdlib.h>

/* A growable int array — the C analog of Rust's Vec<i32>, written with kenbi
   ownership annotations. First demo port (demo-driven: surface the gaps). */

typedef struct {
  int *data;
  int len;
  int cap;
} vec_t;

// @mem vec::self { free: free, owner: v }
// @owns
vec_t *vec_new(void) {
  vec_t *v = malloc(sizeof(vec_t));
  v->len = 0;
  v->cap = 0;
  v->data = NULL;
  return v;                       // ownership transfers to caller (@owns)
}

// @frees(v)
void vec_free(vec_t *v) {
  free(v->data);                  // free the buffer
  free(v);                        // free the struct
}

// @borrows(v)
int vec_push(vec_t *v, int x) {
  if (v->len == v->cap) {
    int ncap = v->cap == 0 ? 4 : v->cap * 2;
    int *nd = realloc(v->data, ncap * sizeof(int));
    if (!nd) return -1;
    v->data = nd;                 // realloc result stored into the struct
    v->cap = ncap;
  }
  v->data[v->len++] = x;
  return 0;
}

// @borrows(v)
int vec_get(const vec_t *v, int i) {
  return v->data[i];
}

void demo(void) {
  vec_t *v = vec_new();
  for (int i = 0; i < 10; i++) vec_push(v, i);
  int sum = 0;
  for (int i = 0; i < 10; i++) sum += vec_get(v, i);
  vec_free(v);
}
