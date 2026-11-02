#include <cstdlib>
// SOUNDNESS: a function-like definition nested in a namespace, an `extern "C"` block, a class
// (member function), or a function template used to fall OUT of analysis with no diagnostic —
// the collector only looked at top-level ckFunctionDecl and did not recurse. A double free in
// any of them was reported "ok" (a false GREEN by omission). Reproduced on real KIR-generated
// C++, which nests everything in namespaces / extern "C". Every one must now be analysed.

namespace ns {
  void in_namespace() {
    /* @mem j::b { free: free, owner: p } */
    char *p = (char *)malloc(8);
    free(p);
    free(p);   // double free inside a namespace   //EXPECT DOUBLE_FREE
  }
}

extern "C" {
  void in_extern_c() {
    /* @mem j::b { free: free, owner: p } */
    char *p = (char *)malloc(8);
    free(p);
    free(p);   // double free inside extern "C"   //EXPECT DOUBLE_FREE
  }
}

struct S {
  void method() {
    /* @mem j::b { free: free, owner: p } */
    char *p = (char *)malloc(8);
    free(p);
    free(p);   // double free inside a member function   //EXPECT DOUBLE_FREE
  }
};

template<typename T> void in_template() {
  /* @mem j::b { free: free, owner: p } */
  char *p = (char *)malloc(8);
  free(p);
  free(p);   // double free inside a function template   //EXPECT DOUBLE_FREE
}
void instantiate() { in_template<int>(); }
