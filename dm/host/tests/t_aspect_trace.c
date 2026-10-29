// Actual guest display-query and layer hooks: diagnostics must not override geometry.
#include "../hle_oe.c"
#include "../../gfx/hle_vi.c"
#include <mach-o/getsect.h>
#include <unistd.h>
static int bound, autoclear;
static void *event_pointer;
void dm_thread_native_wait(int entering) { (void)entering; }
uint64_t now_ns(void) { return 0; }
void dm_audio_suspend(int on) { (void)on; }
void guest_clock_freeze_for(int reason, int on) { (void)reason; (void)on; }
void dm_gfx_suspend(int on) { (void)on; }
uint64_t dm_nvn_frame_count(void) { return 0; }
void hle_bind_system_event(void *ev, int clear) { bound++; autoclear = clear; event_pointer = ev; }
void hle_signal_system_event(void *ev) { (void)ev; }
void hle_clear_system_event(void *ev) { (void)ev; }
extern const struct mach_header_64 _mh_execute_header;
static int checks, failures;
#define CHECK(c, message) do { checks++; if (!(c)) { failures++; printf("FAIL: %s\n", message); } } while (0)
static void *hook(const char *name) {
    unsigned long bytes = 0; void *fn = NULL; unsigned count = 0;
    const hle_force_ent *entries = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &bytes);
    for (size_t i = 0; entries && i < bytes / sizeof *entries; i++) if (!strcmp(entries[i].name, name)) { fn = entries[i].fn; count++; }
    CHECK(count == 1 && fn, name); return fn;
}
int main(void) {
    unsetenv("DM_OE_SCRIPT"); unsetenv("DM_ASPECT_TRACE"); g_aspect_trace_on = -1; g_aspect_trace_count = 0;
    FILE *capture = tmpfile(); int saved = dup(STDERR_FILENO);
    CHECK(capture && saved >= 0, "capture available"); if (!capture || saved < 0) return 1;
    fflush(stderr); dup2(fileno(capture), STDERR_FILENO);
    void (*resolution)(int *, int *) = hook("_ZN2nn2oe27GetDefaultDisplayResolutionEPiS1_");
    void (*resolution_event)(void *) = hook("_ZN2nn2oe38GetDefaultDisplayResolutionChangeEventEPNS_2os11SystemEventE");
    Result (*create)(void **, void *, int, int) = hook("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayEii");
    Result (*crop)(void *, int, int, int, int) = hook("_ZN2nn2vi12SetLayerCropEPNS0_5LayerEiiii");
    int w = -1, h = -1; g_opmode = 1; errno = EDOM; resolution(&w, &h);
    CHECK(w == 1920 && h == 1080 && errno == EDOM, "default docked geometry/error unchanged");
    fflush(stderr); CHECK(ftell(capture) == 0, "default query trace off");
    setenv("DM_ASPECT_TRACE", "1", 1); g_aspect_trace_on = -1;
    errno = ERANGE; resolution(&w, &h);
    CHECK(w == 1920 && h == 1080 && errno == ERANGE, "traced docked answer remains stock");
    g_opmode = 0; resolution(&w,&h);
    CHECK(w == 1280 && h == 720, "traced handheld answer remains stock");
    h = -1; resolution(NULL, &h); CHECK(h == 720, "null width output remains supported");
    resolution(NULL, NULL); CHECK(g_aspect_trace_count == 4, "null outputs still record an actual query");
    uint8_t event[0x100]; resolution_event(event);
    CHECK(bound == 1 && event_pointer == event && autoclear == 0, "change event retains one unsignaled binding");
    int correct = 1;
    for (int i = 0; i < 200; i++) { resolution(&w,&h); correct &= w == 1280 && h == 720; }
    CHECK(correct && g_aspect_trace_count == 16, "bounded query tracing never changes repeated answers");
    fflush(stderr); long query_bytes = ftell(capture);
    void *layer = NULL; CHECK(create(&layer, NULL, 1920, 1080) == RES_OK && layer, "actual sized layer hook still succeeds");
    dm_vi_layer_size(&w,&h); CHECK(w == 1920 && h == 1080, "layer geometry comes from its guest arguments");
    CHECK(crop(layer, 12, 8, 1280, 720) == RES_OK, "actual guest crop hook succeeds");
    int rect[4]; dm_vi_layer_crop(rect);
    CHECK(rect[0] == 12 && rect[1] == 8 && rect[2] == 1280 && rect[3] == 720, "crop is retained independently of display query");
    fflush(stderr); dup2(saved, STDERR_FILENO); close(saved); rewind(capture);
    char text[16384]; size_t bytes = fread(text, 1, sizeof text - 1, capture); text[bytes] = 0; fclose(capture);
    int lines = 0; for (long i = 0; i < query_bytes; i++) if (text[i] == '\n') lines++;
    CHECK(lines == 16, "only first sixteen actual query/event calls logged");
    CHECK(strstr(text,"aspect query 1/16 _ZN2nn2oe27GetDefaultDisplayResolutionEPiS1_ answer=1920x1080") && strstr(text,"answer=1280x720"), "bounded trace identifies symbol and stock answers");
    CHECK(strstr(text,"GetDefaultDisplayResolutionChangeEvent") && strstr(text,"vi::CreateLayer 1920x1080") && strstr(text,"vi::SetLayerCrop 12,8 1280x720"), "existing layer logs and new query log expose separate boundaries");
    printf("aspect trace: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
