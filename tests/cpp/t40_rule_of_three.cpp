#include <cstdlib>
#include <cstring>
// A CLASS THAT OWNS A RESOURCE HAS TO SAY WHAT COPYING IT MEANS. `@raii` declares that instances
// own something the destructor releases, and kenbi already verifies the destructor keeps that
// promise. The promise is only worth as much as the class's copy semantics: if the compiler may
// still copy the object member-wise, the copy hands a second object the same pointer and both
// destructors release it.
//
// The finding is raised AT THE COPY, not on the class. A class that could be copied wrongly but
// never is has no double free, and saying otherwise on every owning class would be noise rather
// than a finding. A copy in another translation unit is caught there by the same check — the
// `@raii` declaration travels in the header that unit includes.
//
// Two checks, both about whether the necessary check is ON THE PATH: that the copy operation
// exists at all (written, or `= delete`d so copying is impossible), and that an `operator=`
// which RELEASES before it READS the source survives `x = x`.

// --- 1. owns a resource, no copy constructor -------------------------------------------------
// @raii(NoCopyCtor)
class NoCopyCtor {
public:
  NoCopyCtor(const char *s) {
    /* @mem t::a { free: delete, owner: data } */
    this->data = new char[8];
    (void) s;
  }
  ~NoCopyCtor() { delete[] data; }
  NoCopyCtor &operator=(const NoCopyCtor &o) {
    if (&o != this) { char *n = new char[8]; delete[] data; data = n; }   //EXPECT UNKNOWN_VAR
    return *this;
  }
private:
  char *data;
};

// @kenbi
static void copies_it(void) {
  NoCopyCtor a("one");
  NoCopyCtor b(a);   //EXPECT MISSING_COPY_CONTROL
  (void) b;
}

// ...but the same class, merely DECLARED and never copied, is not a finding.
// @kenbi
static void only_uses_it(void) {
  NoCopyCtor a("one");
  (void) a;
}

// --- 2. owns a resource, no copy ASSIGNMENT operator -----------------------------------------
// @raii(NoCopyAssign)
class NoCopyAssign {
public:
  NoCopyAssign() {
    /* @mem t::b { free: delete, owner: data } */
    this->data = new char[8];
  }
  ~NoCopyAssign() { delete[] data; }
  NoCopyAssign(const NoCopyAssign &o) { data = new char[8]; (void) o; }
private:
  char *data;
};

// @kenbi
static void assigns_it(void) {
  NoCopyAssign a, b;
  b = a;   //EXPECT MISSING_COPY_CONTROL
}

// --- 3. both written: copying is defined, nothing to report ----------------------------------
// @raii(Correct)
class Correct {
public:
  Correct() {
    /* @mem t::c { free: delete, owner: data } */
    this->data = new char[8];
  }
  ~Correct() { delete[] data; }
  Correct(const Correct &o) { data = new char[8]; (void) o; }
  Correct &operator=(const Correct &o) {
    if (&o != this) { char *n = new char[8]; delete[] data; data = n; }   //EXPECT UNKNOWN_VAR
    return *this;
  }
private:
  char *data;
};

// @kenbi
static void copies_the_correct_one(void) {
  Correct a;
  Correct b(a);
  Correct c;
  c = a;
  c = c;          // self-assignment through a self-safe operator: nothing to report
  (void) b;
}

// --- 4. `x = x` must not read what the operator just freed -----------------------------------
// @raii(SelfUnsafe)
class SelfUnsafe {
public:
  SelfUnsafe() {
    /* @mem t::d { free: delete, owner: data } */
    this->data = new char[8];
  }
  ~SelfUnsafe() { delete[] data; }
  SelfUnsafe(const SelfUnsafe &o) { data = new char[8]; (void) o; }
  // releases first, then reads the source — on a self-assignment that read is of freed memory.
  // (`@kenbi` binds by NAME, so this marker adopts every `operator=` in the file — which is why
  // the other three report their field-origin advisory below.)
  // @kenbi
  SelfUnsafe &operator=(const SelfUnsafe &o) {   //EXPECT SELF_ASSIGN_UNSAFE
    delete[] this->data;   //EXPECT UNKNOWN_VAR
    this->data = new char[strlen(o.data) + 1];
    strcpy(this->data, o.data);
    return *this;
  }
private:
  char *data;
};

// ...and writing the self-assignment out is reported where it breaks, too. The operator says
// where to fix it; the call says what this path does.
// @kenbi
static void assigns_to_itself(void) {
  SelfUnsafe a;
  a = a;   //EXPECT SELF_ASSIGN_UNSAFE
}

// --- 5. reading before releasing is self-safe without any guard (copy-and-swap) --------------
// @raii(SelfSafeByOrder)
class SelfSafeByOrder {
public:
  SelfSafeByOrder() {
    /* @mem t::e { free: delete, owner: data } */
    this->data = new char[8];
  }
  ~SelfSafeByOrder() { delete[] data; }
  SelfSafeByOrder(const SelfSafeByOrder &o) { data = new char[8]; (void) o; }
  SelfSafeByOrder &operator=(const SelfSafeByOrder &o) {
    char *fresh = new char[strlen(o.data) + 1];
    strcpy(fresh, o.data);
    delete[] this->data;      // the source was read before anything was released   //EXPECT UNKNOWN_VAR
    this->data = fresh;
    return *this;
  }
private:
  char *data;
};
