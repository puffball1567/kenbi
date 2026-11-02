/* Independent synthetic API; this is not a hardware driver specification. */
extern void acknowledge_event(void);
extern void wait_for_event(void);
extern void configure_resource(void);

void service_event(void) { acknowledge_event(); }
void configure_helper(void) { configure_resource(); }
void configure_entry(void) { configure_helper(); }
void blocking_entry(void) { wait_for_event(); }
