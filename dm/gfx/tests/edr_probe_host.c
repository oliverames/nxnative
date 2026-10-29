// Synthetic headroom for the GPU color-transform test, never a display claim.
#include <stdatomic.h>
_Atomic float edr_probe_headroom = 2;
float front_present_edr_headroom(void) { return atomic_load(&edr_probe_headroom); }
