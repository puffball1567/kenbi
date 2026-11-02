/* Independently authored inputs: functions whose execution time limits are judged from external
   timing evidence. */
int handler(int x) { return x + 1; }
int slow_handler(int x) { return x * 3; }
int measured_only(int x) { return x - 1; }
int measured_and_bounded(int x) { return x ^ 1; }
int no_evidence(int x) { return x; }
int in_nanoseconds(int x) { return x | 1; }
int two_bounds(int x) { return x & 1; }
