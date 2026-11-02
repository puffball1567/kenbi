#include <cstdlib>
#include <new>
// THE RAII PROMISE, VERIFIED. `@raii(Class)` declares (by name — the class may be declared in a
// header) that instances own what their constructor allocates into a raw member and that the
// destructor releases it. kenbi checks the implementation: the destructor enters owning every
// member a constructor allocated; one it never frees is a LEAK, one it frees twice a
// DOUBLE_FREE (the Juliet 83 / 84 shape: data passed to a class constructor and destructor).

class Holder {
public:
  Holder();
  ~Holder();
private:
  char *data;
};

// @raii(Holder)
Holder::Holder() {
  /* @mem t::h { free: free, owner: data } */
  data = (char *)malloc(100);
}
Holder::~Holder() {
  free(data);
}

class Leaky {
public:
  Leaky();
  ~Leaky();
private:
  char *data;
};

// @raii(Leaky)
Leaky::Leaky() {
  /* @mem t::l { free: free, owner: data } */
  data = (char *)malloc(100);
}
Leaky::~Leaky() {   //EXPECT LEAK
  ;
}

class Twice {
public:
  Twice();
  ~Twice();
private:
  char *data;
};

// @raii(Twice)
Twice::Twice() {
  /* @mem t::w { free: free, owner: data } */
  data = (char *)malloc(100);
}
Twice::~Twice() {
  free(data);
  free(data);   //EXPECT DOUBLE_FREE
}

// instances are RAII owners: a local never leaks, the class's own destructor is the release
static int use_holder() {
  Holder h;
  Leaky l;
  return 0;
}

// the constructor allocates AND releases the member: the destructor's release is a second one
class CtorFrees {
public:
  CtorFrees();
  ~CtorFrees();
private:
  char *data;
};

// @raii(CtorFrees)
CtorFrees::CtorFrees() {
  /* @mem t::cf { free: free, owner: data } */
  data = (char *)malloc(100);
  free(data);
}
CtorFrees::~CtorFrees() {
  free(data);   //EXPECT DOUBLE_FREE
}

// the same with `new[]` / `delete[]` on the member
class ArrTwice {
public:
  ArrTwice();
  ~ArrTwice();
private:
  char *data;
};

// @raii(ArrTwice)
ArrTwice::ArrTwice() {
  /* @mem t::at { free: delete, owner: data } */
  data = new (std::nothrow) char[100];
  delete[] data;
}
ArrTwice::~ArrTwice() {
  delete[] data;   //EXPECT DOUBLE_FREE
}
