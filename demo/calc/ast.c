#include "ast.h"
/* AST node constructors — nodes live in the arena (region-owned). */
ast_t *ast_num(arena_t *a, int v) {
  ast_t *n = arena_alloc(a, sizeof(ast_t));
  n->kind = AST_NUM;
  n->val = v;
  n->left = NULL;
  n->right = NULL;
  return n;
}
ast_t *ast_bin(arena_t *a, ast_kind k, ast_t *l, ast_t *r) {
  ast_t *n = arena_alloc(a, sizeof(ast_t));
  n->kind = k;
  n->val = 0;
  n->left = l;
  n->right = r;
  return n;
}
