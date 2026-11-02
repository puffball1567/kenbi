#include <stdlib.h>
#include <string.h>
// A BUFFER REPLACED IN A LOOP. The idiom is everywhere in C: build a bigger buffer, release the
// old one, rebind the pointer (and any cursor into it), continue. Once the old block is
// released and nothing names it any more, it can be neither used nor released again — so its
// freed state must not travel to the loop head, where it made the REBOUND cursor look like a
// use of freed memory and the next release like a double free. The diverted paths (`break` /
// `continue`) carry their own bindings for the same reason: what is live on THAT path decides
// which origins still matter at the join.

// @allocator s::str { alloc: dup_str, free_returns_null: destroy_str }
char *dup_str(const char *s);
char *destroy_str(char *s);
void concat(char **s, const char *t);
// @borrows(s)
void use(const char *s);

// replace-and-continue
static void regrow_continue(const char *src) {
  char *buf = dup_str(src);
  char *q = buf;
  while (*q != '\0') {
    if (*q == 'x') {
      char *bigger = dup_str(buf);
      concat(&bigger, "more");
      size_t off = (size_t)(q - buf);
      buf = destroy_str(buf);
      buf = bigger;
      q = buf + off;
      continue;
    }
    q++;
  }
  use(q);
  buf = destroy_str(buf);
}

// the same with if / else
static void regrow_else(const char *src) {
  char *buf = dup_str(src);
  char *q = buf;
  while (*q != '\0') {
    if (*q == 'x') {
      char *bigger = dup_str(buf);
      size_t off = (size_t)(q - buf);
      buf = destroy_str(buf);
      buf = bigger;
      q = buf + off;
    } else {
      q++;
    }
  }
  buf = destroy_str(buf);
}

// ... and the genuine hazards in the same shape are still caught: a release with the old
// pointer still live afterwards is a use after free
static void real_uaf(const char *src) {
  char *buf = dup_str(src);
  char *q = buf;
  buf = destroy_str(buf);
  use(q);   //EXPECT USE_AFTER_FREE
}

// ... and releasing the replaced buffer twice
static void real_double(const char *src) {
  char *buf = dup_str(src);
  char *bigger = dup_str(buf);
  buf = destroy_str(buf);
  buf = bigger;
  bigger = destroy_str(bigger);
  buf = destroy_str(buf);   //EXPECT DOUBLE_FREE
}
