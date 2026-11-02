#include <stdlib.h>
// A LOCAL POINTER IS NOT THE OBJECT. A field allocated into a struct the function OWNS leaks when
// that struct dies (t163). But `cur = tree->root` borrows a node out of a structure that outlives
// this frame: only the HANDLE dies at scope exit, and what becomes of a field stored through it is
// its owner's business — the same reason a pointer PARAMETER container defers.
//
// The two are indistinguishable in the field's display name, which normalises `s.buf` and `p->buf`
// alike, so the declared type decides: an automatic-storage local of POINTER type is a handle, a
// stack struct is the object. ImageMagick walks its colour-cube and xml trees exactly this way —
// `node_info=cube_info->root; node_info->list=AcquireQuantumMemory(...)` — and every such store
// read as a leak.
typedef struct node_t { struct node_t *child; int *buf; } node_t;
typedef struct { node_t *root; } tree_t;

// GREEN: the node belongs to the tree, which outlives the call.
// @kenbi
void store_through_borrowed(tree_t *tree, int n) {
  node_t *cur = tree->root;
  /* @mem demo::nbuf { free: free, owner: buf } */
  cur->buf = malloc(n * sizeof(int));
}

// GREEN: still a borrowed handle after a walk.
// @kenbi
void store_after_walk(tree_t *tree, int n) {
  node_t *cur = tree->root;
  while (cur->child != (node_t *) 0)
    cur = cur->child;
  /* @mem demo::wbuf { free: free, owner: buf } */
  cur->buf = malloc(n * sizeof(int));
}

// RED: a heap container this function DOES own still leaks its field — the handle is tracked, so
// the object is ours and dies here with the field unreleased.
// @kenbi
void owned_container(int n) {
  /* @mem demo::node { free: free, owner: own } */
  node_t *own = (node_t *) malloc(sizeof(node_t));   //EXPECT LEAK
  /* @mem demo::obuf { free: free, owner: buf } */
  own->buf = malloc(n * sizeof(int));   //EXPECT LEAK
}
