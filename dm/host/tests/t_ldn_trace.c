// Actual swforce hooks, opaque buffers kept untouched, bounded iOS-compatible trace.
#include "../hle_offline.c"
#include <mach-o/getsect.h>
#include <time.h>
#include <unistd.h>
static int bound, autoclear, checks, failures;
static void *event_pointer;
void hle_bind_system_event(void *ev, int clear) { bound++; event_pointer = ev; autoclear = clear; }
void dm_guest_sleep_ns(int64_t ns) { (void)ns; }
extern const struct mach_header_64 _mh_execute_header;
#define CHECK(c, message) do { checks++; if (!(c)) { failures++; printf("FAIL: %s\n", message); } } while (0)
static void *hook(const char *name) {
    unsigned long bytes = 0; void *fn = NULL; unsigned count = 0;
    const hle_force_ent *entries = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &bytes);
    for (size_t i = 0; entries && i < bytes / sizeof *entries; i++) if (!strcmp(entries[i].name, name)) { fn = entries[i].fn; count++; }
    CHECK(count == 1 && fn, name); return fn;
}
#define HOOK(cname, type) ((type)hook(hle_force_##cname.name))
int main(void) {
    FILE *capture = tmpfile(); int saved = dup(STDERR_FILENO);
    CHECK(capture && saved >= 0, "capture available"); if (!capture || saved < 0) return 1;
    fflush(stderr); dup2(fileno(capture), STDERR_FILENO);
    Result (*initialize)(void) = HOOK(h_ldn_Init, Result (*)(void));
    int (*state)(void) = HOOK(h_ldn_State, int (*)(void));
    unsetenv("DM_LDN_TRACE"); g_ldn_trace_on = -1; g_ldn_trace_count = 0;
    errno = EDOM; CHECK(initialize() == RES_FAIL && errno == EDOM, "default init/error unchanged");
    fflush(stderr); CHECK(ftell(capture) == 0, "default trace off");
    setenv("DM_LDN_TRACE", "1", 1); g_ldn_trace_on = -1;
    errno = ERANGE; CHECK(initialize() == RES_FAIL && errno == ERANGE, "traced init/error unchanged");
    CHECK(state() == 0, "state remains none");
    uint8_t output[64], unchanged[64], event[0x100]; memset(output, 0xa5, sizeof output); memcpy(unchanged, output, sizeof output);
    HOOK(h_ldn_Attach, void (*)(void *))(event);
    CHECK(bound == 1 && event_pointer == event && autoclear == 0, "event bound once with original autoclear");
    int n = 999;
    CHECK(HOOK(h_ldn_Scan, Result (*)(void *, int *, int, const void *, int))(output, &n, 5, (void *)1, 0) == RES_FAIL && n == 0 && !memcmp(output, unchanged, sizeof output), "scan count zero, opaque output/filter untouched");
    n = 999;
    CHECK(HOOK(h_ldn_ScanP, Result (*)(void *, int *, int, const void *, int))(output, &n, 7, (void *)1, 0) == RES_FAIL && n == 0 && !memcmp(output, unchanged, sizeof output), "private scan unchanged");
    CHECK(HOOK(h_ldn_Adv, Result (*)(const void *, uint64_t))((void *)1, 1234) == RES_FAIL, "advertise count logged without reading data");
    CHECK(HOOK(h_ldn_CreateP, Result (*)(const void *, const void *, const void *, const void *, int, const void *))((void *)1,(void *)1,(void *)1,(void *)1,3,(void *)1) == RES_FAIL, "private create does not inspect security or address entries");
    CHECK(HOOK(h_ldn_Create, Result (*)(const void *, const void *, const void *))((void *)1,(void *)1,(void *)1) == RES_FAIL, "create stays unavailable");
    CHECK(HOOK(h_ldn_Connect, Result (*)(const void *, const void *, const void *, int, int))((void *)1,(void *)1,(void *)1,2,0) == RES_FAIL, "connect stays unavailable");
    CHECK(HOOK(h_ldn_ConnectP, Result (*)(const void *, const void *, const void *, const void *, int, int))((void *)1,(void *)1,(void *)1,(void *)1,2,0) == RES_FAIL, "private connect stays unavailable");
    CHECK(HOOK(h_ldn_NetInfo, Result (*)(void *))(output) == RES_FAIL && !memcmp(output, unchanged, sizeof output), "network info remains untouched");
    CHECK(HOOK(h_ldn_NetCfg, Result (*)(void *))(output) == RES_FAIL && !memcmp(output, unchanged, sizeof output), "network config remains untouched");
    CHECK(HOOK(h_ldn_SecPrm, Result (*)(void *))(output) == RES_FAIL && !memcmp(output, unchanged, sizeof output), "security output remains untouched");
    uint32_t ip = 1, mask = 2;
    CHECK(HOOK(h_ldn_Ip, Result (*)(uint32_t *, uint32_t *))(&ip,&mask) == RES_FAIL && !ip && !mask, "IP outputs retain existing zero/failure behavior");
    CHECK(HOOK(h_ldn_OpenSta, Result (*)(void))() == RES_FAIL, "open station unavailable");
    CHECK(HOOK(h_ldn_CloseSta, Result (*)(void))() == RES_FAIL, "close station unavailable");
    CHECK(HOOK(h_ldn_OpenAp, Result (*)(void))() == RES_FAIL, "open AP unavailable");
    CHECK(HOOK(h_ldn_CloseAp, Result (*)(void))() == RES_FAIL, "close AP unavailable");
    CHECK(HOOK(h_ldn_Disc, Result (*)(void))() == RES_FAIL, "disconnect unavailable");
    CHECK(HOOK(h_ldn_Destroy, Result (*)(void))() == RES_FAIL, "destroy unavailable");
    CHECK(HOOK(h_ldn_DiscReason, int (*)(void))() == 0, "disconnect reason unchanged");
    CHECK(HOOK(h_ldn_Filter, Result (*)(uint64_t))(0xabcdef) == RES_FAIL, "filter unavailable");
    CHECK(HOOK(h_ldn_Policy, Result (*)(int))(1) == RES_FAIL, "accept policy unavailable");
    CHECK(HOOK(h_ldn_Reject, Result (*)(uint32_t))(0x12345678) == RES_FAIL, "reject unavailable");
    HOOK(h_ldn_Fini, void (*)(void))();
    CHECK(g_ldn_trace_count == 25, "each distinct actual hook traced once");
    int states_unchanged = 1; for (int i = 0; i < 500; i++) states_unchanged &= state() == 0;
    CHECK(states_unchanged, "trace cap never changes returned state");
    CHECK(g_ldn_trace_count == 64, "trace count saturates at 64");
    fflush(stderr); dup2(saved, STDERR_FILENO); close(saved); rewind(capture);
    char text[32768]; size_t bytes = fread(text, 1, sizeof text - 1, capture); text[bytes] = 0; fclose(capture);
    unsigned lines = 0; for (char *p = text; *p; p++) if (*p == '\n') lines++;
    CHECK(lines == 64, "only 64 lines emitted despite repeated polling");
    CHECK(strstr(text, "ldn trace 1/64 _ZN2nn3ldn10InitializeEv offline result=") && strstr(text, "ldn trace 2/64 _ZN2nn3ldn8GetStateEv"), "full symbols and ordered sequence identify real calls");
    CHECK(strstr(text, "capacity=5 output_count=0") && strstr(text,"byte_count=1234") && strstr(text,"address_count=3"), "safe scalar counts included");
    CHECK(!strstr(text,"abcdef") && !strstr(text,"12345678") && !strstr(text,"0x1 "), "no identity or opaque pointer logged");
    CHECK(bound == 1, "tracing did not bind or signal any extra event");
    printf("ldn trace: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
