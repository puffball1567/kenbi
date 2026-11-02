#include <stdlib.h>
// A FRESH-DEST REALLOC IS A PAIR, AND THE NULL TEST IS WHAT SETTLES IT.
//
// `q = realloc(p, n)` puts the program in a state where which handle names the block depends on
// something that has not been looked at yet: on OOM realloc returns NULL and the block is still
// the one `p` holds; on success the block is `q` and `p` is dangling. Both handles are therefore
// untouchable until a path learns the answer — which is exactly what the idiom's `if (q)` does,
// and its two branches learn opposite things.
//
// kenbi ties the pair at the realloc, settles the tie on each branch of the test of the RESULT,
// and reports at the touch rather than at the realloc. So the standard idiom verifies with no
// annotation at all, while every shape that skips the reconciliation stays default-red.

// @borrows(p)
void use(const char *p);
int maybe(void);

// --- GREEN: the failure branch bails out after releasing the original ------------------------
// @kenbi
void reconcile_by_early_return(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (tmp == NULL) { free(p); return; }   /* the resize failed: p still owns the block */
  p = tmp;                                /* the resize succeeded: re-bind, p owns it again */
  free(p);
}

// --- GREEN: the result is used on the success branch, the original on the failure branch -----
// @kenbi
void reconcile_in_both_branches(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (tmp != NULL) {
    use(tmp);
    free(tmp);
  } else {
    use(p);
    free(p);
  }
}

// --- RED: the failure branch forgets the original --------------------------------------------
// `if (tmp == NULL) return;` abandons the block p still holds.
// @kenbi
void failure_branch_leaks(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (tmp == NULL) return;
  p = tmp;
  free(p);
}

// --- RED: the source is read after a realloc that succeeded ----------------------------------
// Inside the success branch the block may have moved, so `p` is a handle to the old one.
// @kenbi
void source_used_after_success(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (tmp != NULL) {
    use(p);   //EXPECT REALLOC_UNVERIFIED
    free(tmp);
  } else {
    free(p);
  }
}

// --- RED: either half touched before the test ------------------------------------------------
// @kenbi
void result_used_before_the_test(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  use(tmp);   //EXPECT REALLOC_UNVERIFIED
  if (tmp) p = tmp;
  free(p);
}

// --- RED: a test of the SOURCE decides nothing -----------------------------------------------
// `p` is not what realloc returned, so its value says nothing about whether the resize succeeded.
// @kenbi
void testing_the_source_settles_nothing(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (p != NULL) free(p);   //EXPECT REALLOC_UNVERIFIED
}

// --- RED: both halves released ---------------------------------------------------------------
// @kenbi
void both_halves_released(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (tmp) p = tmp;
  free(p);
  free(tmp);   //EXPECT DOUBLE_FREE
}

// --- RED: a runtime-conditional realloc leaves the pair tied at the join ----------------------
// @kenbi
void tied_on_one_path_only(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  if (maybe()) {
    char *tmp = (char *)realloc(p, n);
    (void)tmp;
  }
  free(p);   //EXPECT REALLOC_UNVERIFIED
}

// --- RED: the tie survives every control-flow edge, not only the if-join --------------------
// A `goto` out of the window, a loop `break`, a `switch` case and a `continue` all carry the
// unsettled pair with them — otherwise whichever edge reached the join last would launder it.
// @kenbi
void tie_survives_goto(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (maybe()) goto done;
  if (tmp) p = tmp;
done:
  free(p);   //EXPECT REALLOC_UNVERIFIED
}

// @kenbi
void tie_survives_loop_break(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp;
  for (;;) { tmp = (char *)realloc(p, n); break; }
  free(p);   //EXPECT REALLOC_UNVERIFIED
}

// @kenbi
void tie_survives_switch(int n, int k) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp;
  switch (k) {
    case 1: tmp = (char *)realloc(p, n); break;
    default: break;
  }
  free(p);   //EXPECT REALLOC_UNVERIFIED
}

// @kenbi
void tie_survives_continue(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp;
  while (maybe()) {
    tmp = (char *)realloc(p, n);
    continue;
  }
  free(p);   //EXPECT REALLOC_UNVERIFIED
}

// --- RED: an ALIAS of an unsettled handle is just as unusable -------------------------------
// @kenbi
void alias_does_not_launder(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  char *alias = tmp;
  free(alias);   //EXPECT REALLOC_UNVERIFIED
}

// --- RED: resizing a handle whose own block may already have moved --------------------------
// @kenbi
void resize_of_a_stale_handle(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (tmp != NULL) {
    char *again = (char *)realloc(p, 2 * n);   //EXPECT REALLOC_UNVERIFIED
    (void)again;
    free(tmp);
  } else {
    free(p);
  }
}

// --- RED: releasing a result the path knows is NULL is the defined no-op --------------------
// It does not discharge anything, so the block the source still holds is a leak.
// @kenbi
void free_of_the_null_result(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) return;
  char *tmp = (char *)realloc(p, n);
  if (tmp != NULL) {
    p = tmp;
    free(p);
  } else {
    free(tmp);   /* free(NULL) — the original is still p's, and nothing releases it */
  }
}
