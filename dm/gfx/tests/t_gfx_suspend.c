// CPU-only lifecycle regression: the real NVN submit entry and graphics gate,
// with Metal replay/drain replaced by a prepare step controlled by semaphores.
#include <pthread.h>
#include <stdatomic.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <time.h>

static int observed_mutex_lock(pthread_mutex_t *mutex);
#define pthread_mutex_lock observed_mutex_lock
#define mtl_sub_begin test_sub_begin
#define mtl_sub_commit test_sub_commit
#define mtl_queue_activate test_queue_activate
#define mtl_set_queue_origin_lower_left test_queue_origin
#define mtl_sub_index test_sub_index
#define mtl_exec_rest test_exec_rest
#define mtl_drain test_drain
#include "../nvn/hle_nvn.c"
#undef pthread_mutex_lock
#undef mtl_sub_begin
#undef mtl_sub_commit
#undef mtl_queue_activate
#undef mtl_set_queue_origin_lower_left
#undef mtl_sub_index
#undef mtl_exec_rest
#undef mtl_drain

uint64_t g_t0_ns;
_Atomic uint64_t dm_present_ns;
module_t *g_mod; int g_nmod;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void svc_thread_dump(void) {}
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void dm_vi_layer_crop(int c[4]) { memset(c, 0, 4 * sizeof *c); }
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }

static dispatch_semaphore_t preparing, second_waiting, finish_prepare, reentering, suspended, returned;
static __thread int second_submit;
static _Atomic int begins, commits, drains;
static int inflight_at_serial_wait, host_work_at_serial_wait;
static int observed_mutex_lock(pthread_mutex_t *mutex) {
    if (mutex == &g_sub_mu && second_submit) {
        pthread_mutex_lock(&g_susp_mu);
        inflight_at_serial_wait = g_inflight_api; host_work_at_serial_wait = dm_host_work;
        pthread_mutex_unlock(&g_susp_mu);
        dispatch_semaphore_signal(second_waiting);
    }
    return pthread_mutex_lock(mutex);
}
void test_sub_begin(void) {
    if (atomic_fetch_add(&begins, 1) == 0) {
        dm_gfx_leave();   // the prepare step in mtl_sub_begin, outside the graphics gate
        dispatch_semaphore_signal(preparing);
        dispatch_semaphore_wait(finish_prepare, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_signal(reentering);
        dm_gfx_enter();
    }
}
uint64_t test_sub_commit(void) { atomic_fetch_add(&commits, 1); return 0; }
void test_queue_activate(uint64_t serial) { (void)serial; }
void test_queue_origin(int on) { (void)on; }
void test_sub_index(const uint64_t *handles, int count) { (void)handles; (void)count; }
void test_exec_rest(const uint64_t *handles, int count) { (void)handles; (void)count; }
void test_drain(void) { atomic_fetch_add(&drains, 1); }

static NVNqueue queues[2];
static void *submit(void *which) {
    second_submit = which != NULL;
    h_nvnQueueSubmitCommands(&queues[second_submit], 0, NULL);
    dispatch_semaphore_signal(returned);
    return NULL;
}
static void *suspend_graphics(void *unused) {
    (void)unused; dm_gfx_suspend(1); dispatch_semaphore_signal(suspended); return NULL;
}
static int checks, failures;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failures += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static int reached(dispatch_semaphore_t semaphore, const char *name) {
    int ok = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    CHECK(name, ok); return ok;
}

int main(void) {
    preparing = dispatch_semaphore_create(0); second_waiting = dispatch_semaphore_create(0);
    finish_prepare = dispatch_semaphore_create(0); reentering = dispatch_semaphore_create(0);
    suspended = dispatch_semaphore_create(0); returned = dispatch_semaphore_create(0);
    pthread_t first, second, background;
    pthread_create(&first, NULL, submit, NULL);
    if (!reached(preparing, "first submission prepares outside graphics gate")) return 1;
    pthread_create(&second, NULL, submit, (void *)1);
    if (!reached(second_waiting, "second submission reaches the serial lock")) return 1;
    CHECK("a queued submission is not in-flight graphics work", inflight_at_serial_wait == 0);
    CHECK("a contended submit remains host work for the guest scheduler", host_work_at_serial_wait > 0);
    if (failures) return 1;   // the old lock order would deadlock the following suspend
    pthread_create(&background, NULL, suspend_graphics, NULL);
    if (!reached(suspended, "suspend completes while preparation owns the serial lock")) return 1;
    pthread_join(background, NULL);
    CHECK("suspend drains graphics exactly once", atomic_load(&drains) == 1);
    dispatch_semaphore_signal(finish_prepare);
    if (!reached(reentering, "finished preparation attempts to reenter graphics gate")) return 1;
    CHECK("no submission commits while graphics are suspended", atomic_load(&commits) == 0);
    dm_gfx_suspend(0);
    if (!reached(returned, "a submission returns after resume") || !reached(returned, "both submissions return after resume")) return 1;
    pthread_join(first, NULL); pthread_join(second, NULL);
    CHECK("both serialized submissions commit", atomic_load(&commits) == 2);
    CHECK("all graphics entries are balanced", g_inflight_api == 0);
    printf("graphics suspend: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
