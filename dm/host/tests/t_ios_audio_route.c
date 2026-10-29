#include <stdio.h>
#include "../../ios/Sources/DmAudioRoutePolicy.h"

int main(void) {
    int failures = 0, checks = 0;
    #define CHECK(name, value) do { checks++; if (!(value)) { failures++; fprintf(stderr, "FAIL: %s\n", name); } } while (0)
    const unsigned routes[] = {1, 2, 4, 6, 7, 8};
    for (unsigned i = 0; i < sizeof routes / sizeof *routes; i++) {
        CHECK("failed foreground activation retries on route events", dm_audio_route_retry(routes[i], 0, 0, 1));
        CHECK("background never activates audio", !dm_audio_route_retry(routes[i], 1, 0, 1));
        CHECK("interruption never activates audio", !dm_audio_route_retry(routes[i], 0, 1, 1));
        CHECK("healthy route keeps native RemoteIO handling", !dm_audio_route_retry(routes[i], 0, 0, 0));
    }
    CHECK("own category notification cannot recurse", !dm_audio_route_retry(3, 0, 0, 1));
    CHECK("unknown notification does not guess", !dm_audio_route_retry(0, 0, 0, 1));
    CHECK("future notification does not guess", !dm_audio_route_retry(99, 0, 0, 1));
    printf("audio route policy: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
