// @kenbi file
// REFERENCE COUNTING in C++: the same discipline with free functions (`node_ref(n)`) and with
// member functions (`o->AddRef()`, `delete this`). A `new` object starts with the count its
// class gives it — the counter's default member initialiser or what its constructors set —
// when kenbi can read that from the class.
#include <cstdlib>
// @allocator rc::heap { alloc: malloc, free: free }
// @refcounted Node { count: refs, retain: node_ref, release: node_unref }
struct Node { int refs; int v; };
// @owns
Node *node_new(int v) {
    Node *n = static_cast<Node *>(malloc(sizeof(Node)));
    if (!n) return nullptr;
    n->refs = 1;
    n->v = v;
    return n;
}
void node_ref(Node *n) { ++n->refs; }
// @frees(n)
void node_unref(Node *n) { if (--n->refs == 0) free(n); }
int ok() {
    Node *n = node_new(1);
    if (n == nullptr) return 0;
    int v = n->v;
    node_unref(n);
    return v;
}
int bad() {
    Node *n = node_new(1);
    if (n == nullptr) return 0;
    node_unref(n);
    return n->v;   //EXPECT COUNT_USE_AFTER_RELEASE
}
// @refcounted Obj { count: refs, retain: AddRef, release: Release }
struct Obj {
    int refs;
    void AddRef() { ++refs; }
    void Release() { if (--refs == 0) delete this; }
};
void method_style(Obj *o) {
    o->AddRef();
    o->Release();
}
int method_over_release(Obj *o) {
    o->Release();   //EXPECT COUNT_OVER_RELEASE
    return o->refs;
}
void method_pinned(Obj *o) {
    o->AddRef();
    o->Release();
    o->Release();   //EXPECT COUNT_OVER_RELEASE
}
// @refcounted Bad { count: refs, retain: Ref, release: Unref }
struct Bad {
    int refs;
    void Ref() { }   //EXPECT COUNT_RETAIN_MISMATCH
    void Unref() { --refs; delete this; }   //EXPECT COUNT_RELEASE_MISMATCH COUNT_RELEASE_MISMATCH
};
// @refcounted Res { count: refs, retain: Ref, release: Unref }
class Res {
public:
    void Ref() { ++refs; }
    void Unref() {
        if (--refs != 0) return;
        delete this;
    }
    int value() const { return v; }
private:
    int refs = 1;
    int v = 0;
};
int res_user(Res *r) {
    r->Ref();
    int v = r->value();
    r->Unref();
    return v;
}
int res_after(Res *r) {
    r->Ref();
    r->Unref();
    r->Unref();   //EXPECT COUNT_OVER_RELEASE
    return r->value();
}
// @owns
Res *res_make() {
    /* @mem rc::res { free: delete, owner: r } */
    Res *r = new Res;
    return r;
}
// @refcounted Raw { count: refs, retain: Ref, release: Unref }
struct Raw {
    int refs;
    void Ref() { ++refs; }
    void Unref() { if (--refs == 0) delete this; }
};
// @owns
Raw *raw_make() {
    /* @mem rc::raw { free: delete, owner: r } */
    Raw *r = new Raw;
    return r;   //EXPECT COUNT_NO_SHARE
}
// @owns
Raw *raw_make_ok() {
    /* @mem rc::raw { free: delete, owner: r } */
    Raw *r = new Raw;
    r->refs = 1;
    return r;
}
int res_scope() {
    Res *r = res_make();   //EXPECT COUNT_LEAK
    if (!r) return 0;
    int v = r->value();
    return v;
}
