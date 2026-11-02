#ifndef AST_H
#define AST_H
#include "arena.h"
typedef enum { AST_NUM, AST_ADD, AST_MUL } ast_kind;
typedef struct ast {
  ast_kind kind;
  int val;
  struct ast *left;
  struct ast *right;
} ast_t;
// @arena_alloc(a)
ast_t *ast_num(arena_t *a, int v);
// @arena_alloc(a)
ast_t *ast_bin(arena_t *a, ast_kind k, ast_t *l, ast_t *r);
int eval(const ast_t *n);
#endif
