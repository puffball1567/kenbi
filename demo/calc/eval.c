#include "ast.h"
/* Evaluate an AST — borrows the tree, frees nothing. */
int eval(const ast_t *n) {
  switch (n->kind) {
    case AST_NUM: return n->val;
    case AST_ADD: return eval(n->left) + eval(n->right);
    case AST_MUL: return eval(n->left) * eval(n->right);
  }
  return 0;
}
