#include "../nvn/nvn_edr.h"
#include <stdio.h>
static int checks, failed;
#define CHECK(name, ok) do { checks++; int pass = !!(ok); failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
int main(void) {
    unsetenv("DM_PRESENT_EDR"); CHECK("EDR is off by default", !nvn_edr_requested());
    setenv("DM_PRESENT_EDR", "0", 1); CHECK("zero keeps SDR", !nvn_edr_requested());
    setenv("DM_PRESENT_EDR", "1", 1); CHECK("one explicitly opts in", nvn_edr_requested());
    setenv("DM_PRESENT_EDR", "true", 1); CHECK("other values do not accidentally opt in", !nvn_edr_requested());
    CHECK("off keeps SDR headroom", nvn_edr_headroom(0, 1, 8, 8) == 1);
    CHECK("an inactive scene keeps SDR", nvn_edr_headroom(1, 0, 8, 8) == 1);
    CHECK("SDR-only display keeps SDR", nvn_edr_headroom(1, 1, 1, 1) == 1);
    CHECK("current headroom limits output", fabsf(nvn_edr_headroom(1, 1, 1.2f, 8) - 1.2f) < 0.00001f);
    CHECK("potential headroom also limits output", nvn_edr_headroom(1, 1, 8, 1.5f) == 1.5f);
    CHECK("experimental boost is capped at two", nvn_edr_headroom(1, 1, 8, 8) == 2);
    CHECK("invalid headroom falls back to SDR", nvn_edr_headroom(1, 1, NAN, 8) == 1);
    CHECK("invalid potential falls back to SDR", nvn_edr_headroom(1, 1, 2, INFINITY) == 1);
    printf("edr policy: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
