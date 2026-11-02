/* A second library in the same project, written so that the three WEAKER contract states are
   all present when the contract set is published (`kenbi --emit-contracts`): a contract whose
   body kenbi did not check, one whose body contradicts it, and one that is checked but rests
   on a boundary kenbi never covered. A published contract that could not say which of these
   it is would let "annotated" pass for "verified". */
// @frees(p)
void ext_take(char *p);
// @frees(p)
void ext_bad(char *p);
// @frees(p)
void ext_trusting(char *p);
