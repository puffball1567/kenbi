// Deleting an object through a pointer to a base class whose destructor is not virtual is
// undefined behaviour ([expr.delete]): the derived destructor does not run, and what it releases
// leaks. Reported when the object was constructed as a derived class in view; when its dynamic
// type is not in view, reported if the class is a base of any class (it cannot be shown not to be
// a derived object). A virtual destructor — declared, or inherited — makes the delete sound.

struct Plain { ~Plain() {} };
struct PlainDerived : Plain { char *name; ~PlainDerived() { delete[] name; } };

struct Virt { virtual ~Virt() {} };
struct Mid : Virt { ~Mid() {} };            // virtual through its base
struct Leaf : Mid { ~Leaf() {} };

struct Alone { ~Alone() {} };               // nothing derives from it

// @kenbi
void derived_through_plain_base() {
  /* @mem t::a { free: delete, owner: b } */
  Plain *b = new PlainDerived;
  delete b;                                 //EXPECT DELETE_NONVIRTUAL_BASE
}

// @kenbi
void same_class_through_plain_base() {
  /* @mem t::b { free: delete, owner: p } */
  Plain *p = new Plain;
  delete p;
}

// @kenbi
void derived_through_virtual_base() {
  /* @mem t::c { free: delete, owner: v } */
  Virt *v = new Leaf;
  delete v;
}

// @kenbi
void derived_through_inherited_virtual() {
  /* @mem t::d { free: delete, owner: m } */
  Mid *m = new Leaf;
  delete m;
}

// @kenbi
// @frees(q)
void unknown_dynamic_type(Plain *q) {
  delete q;                                 //EXPECT DELETE_NONVIRTUAL_BASE
}

// @kenbi
// @frees(r)
void unknown_but_nothing_derives(Alone *r) {
  delete r;
}
