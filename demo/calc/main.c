#include "ast.h"
void print_int(int x);
void run(void) {
  arena_t *R = arena_create();
  ast_t *e = ast_bin(R, AST_ADD,
                     ast_num(R, 1),
                     ast_bin(R, AST_MUL, ast_num(R, 2), ast_num(R, 3)));
  print_int(eval(e));
  arena_destroy(R);            // whole tree freed at once
}
