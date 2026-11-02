/* Original, synthetic device API example. No real hardware specification. */
struct device { unsigned opaque; };
void device_init(struct device *device);
void device_start(struct device *device);
void device_finish(struct device *device);

void initialized_transfer(void) {
  struct device device;
  device_init(&device);
  device_start(&device);
  device_finish(&device);
}

void reset_transfer(void) {
  struct device device;
  device_start(&device);
  device_finish(&device);
}
