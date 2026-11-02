#include <memory>
#include <cstdlib>
// THE LIBRARY SEAM for a std::unique_ptr owner — the point where RAII stops and an existing
// library's manual-memory API begins. Three accessors carry ownership meaning:
//   .get()      hands out a BORROW: a non-owning raw pointer the unique_ptr still releases;
//   .release()  hands out OWNERSHIP: the raw pointer now must be freed (or transferred) by the
//               receiver, and the unique_ptr no longer owns it;
//   .reset(p)   TAKES ownership of a raw p (the owner releases it later).
// A borrow given to a freeing library double-frees with the destructor; an owned release given
// to a borrowing library is never freed. Both are exactly the seam mismatches kenbi checks
// against the library's declared contract on its prototype.

// @frees(p)
void lib_take(int *p) noexcept;     // takes ownership and frees
// @borrows(p)
void lib_read(int *p) noexcept;     // only reads

// .get() is a borrow: deleting it double-frees with the destructor
static void get_then_delete() {
  std::unique_ptr<int> up(new int(1));
  int *p = up.get();
  delete p;   // frees what the owner still releases   //EXPECT FREE_INTERIOR
}

// a borrow handed to a library that FREES — the seam mismatch
static void get_to_freer() {
  std::unique_ptr<int> up(new int(1));
  lib_take(up.get());   // library frees the owner's resource   //EXPECT FREE_INTERIOR
}

// a borrow handed to a library that only READS is fine
static void get_to_reader_ok() {
  std::unique_ptr<int> up(new int(1));
  lib_read(up.get());
}

// .release() hands out an OWNED raw pointer: never freed -> it leaks
static void release_leaks() {
  std::unique_ptr<int> up(new int(1));
  /* @mem seam::raw { free: free, owner: p } */
  int *p = up.release();   //EXPECT LEAK
  (void)p;
}

// .release() to a library that frees: ownership transferred -> clean
static void release_to_freer_ok() {
  std::unique_ptr<int> up(new int(1));
  lib_take(up.release());
}

// .release() to a library that only borrows: the released resource is never freed -> it leaks
static void release_to_borrower_leaks() {
  std::unique_ptr<int> up(new int(1));
  lib_read(up.release());   //EXPECT LEAK
}

// .reset(p): the owner takes p — p stays usable as a BORROW of the owner, so freeing it
// afterwards frees the owner's resource from the wrong side (the owner releases it)
static void reset_takes() {
  std::unique_ptr<int> up;
  /* @mem seam::raw2 { free: free, owner: p } */
  int *p = (int *)malloc(sizeof(int));
  up.reset(p);
  *p = 2;
  free(p);   //EXPECT FREE_INTERIOR
}
