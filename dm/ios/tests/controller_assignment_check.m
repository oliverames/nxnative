// Actual production slot/adapter code with public writable snapshot controllers.
// Host endpoints record routing only; no game, discovery, sensors or rumble run.
#include "../Sources/DmGamepad.m"
#include <time.h>

uint64_t g_t0_ns;
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static uint64_t buttons[DM_PLAYERS];
static GCController *rumble[DM_PLAYERS];
static unsigned cleared[DM_PLAYERS], motion_samples;
static int motion_player;
static uint32_t player_mask;
static NSMutableArray *writes;
void dm_input_set(uint64_t b, int32_t x, int32_t y, int32_t r, int32_t s) { (void)b; (void)x; (void)y; (void)r; (void)s; }
void dm_pad_set_player(int p, uint64_t b, int32_t x, int32_t y, int32_t r, int32_t s) {
    (void)x; (void)y; (void)r; (void)s; buttons[p] = b; [writes addObject:@[@(p),@(b)]];
}
void dm_pad_set(uint64_t b, int32_t x, int32_t y, int32_t r, int32_t s) { dm_pad_set_player(0,b,x,y,r,s); }
void dm_pad_players(uint32_t m) { player_mask = m; }
void dm_motion_set(int p, const float a[3], const float r[3]) { (void)a; (void)r; motion_samples++; motion_player = p; }
void dm_motion_clear(int p) { cleared[p]++; }
void dm_motion_set_switch(int p, const float a[3], const float r[3]) { (void)p; (void)a; (void)r; }
void dm_haptics_apple_controller(int p, GCController *c) { rumble[p] = c; }
void dm_touch_set(const dm_touch *touches, int n) { (void)touches; (void)n; }
uint32_t dm_player_npad(int p) { return (uint32_t)p; }
int dm_opmode(void) { return 0; }

@interface AssignmentMotion : NSObject
@property BOOL hasRotationRate, hasGravityAndUserAcceleration, sensorsRequireManualActivation, sensorsActive;
@property GCAcceleration acceleration, gravity, userAcceleration;
@property GCRotationRate rotationRate;
@property(copy) GCMotionValueChangedHandler valueChangedHandler;
@end
@implementation AssignmentMotion
@end
@interface AssignmentController : NSObject
@property AssignmentMotion *motion;
@property GCExtendedGamepad *extendedGamepad;
@property GCPhysicalInputProfile *physicalInputProfile;
@property dispatch_queue_t handlerQueue;
@property GCControllerPlayerIndex playerIndex;
@property NSString *vendorName;
@end
@implementation AssignmentController
@end

static NSMutableArray *checks;
static void check(NSString *name, BOOL passed) {
    [checks addObject:@{@"name":name,@"passed":@(passed)}];
    fprintf(stderr,"[assignment] %s: %s\n",name.UTF8String,passed ? "PASS" : "FAIL");
}
static void verify_assignment(void) {
    checks = [NSMutableArray array]; writes = [NSMutableArray array];
    unsetenv("DM_PAD_ASSIGN"); unsetenv("DM_PAD_MERGE"); pads_start();
    check(@"assignment is absent by default", !g_assign);
    GCController *a = GCController.controllerWithExtendedGamepad, *b = GCController.controllerWithExtendedGamepad;
    [a.extendedGamepad.buttonA setValue:1]; [b.extendedGamepad.buttonB setValue:1];
    GCControllerPlayerIndex original = a.playerIndex;
    pads_slotted_now(@[a,b],nil);
    check(@"default connection order still assigns players 1 and 2", g_held[0] == a && g_held[1] == b && player_mask == 3);
    check(@"default positional button mapping is unchanged", buttons[0] == DM_BTN_B && buttons[1] == DM_BTN_A);
    check(@"default mode leaves controller player indicators alone", a.playerIndex == original);
    check(@"default mode rejects explicit assignment", !assign_controller(a,1) && g_held[0] == a);
    pads_slotted_now(@[],nil); memset(&g_slots,0,sizeof g_slots);
    setenv("DM_PAD_ASSIGN","1",1); setenv("DM_PAD_MERGE","1",1); pads_start();
    check(@"merge mode keeps assignment disabled", g_merge && !g_assign);
    unsetenv("DM_PAD_MERGE"); pads_start(); check(@"exact opt-in enables assignment", g_assign);
    pads_slotted_now(@[a,b],nil);
    check(@"opt-in input and motion callbacks use the main queue", a.handlerQueue == dispatch_get_main_queue() && b.handlerQueue == dispatch_get_main_queue());
    check(@"supported player indicators follow initial slots", a.playerIndex == GCControllerPlayerIndex1 && b.playerIndex == GCControllerPlayerIndex2);
    [writes removeAllObjects];
    check(@"occupied assignment succeeds as a swap", assign_controller(a,1));
    check(@"both old held states are released before either new state", writes.count >= 4 && [writes[0][1] unsignedLongLongValue] == 0 && [writes[1][1] unsignedLongLongValue] == 0 && [writes[0][0] intValue] != [writes[1][0] intValue]);
    check(@"both connected owners move without a lost player", g_held[0] == b && g_held[1] == a && pad_slot_of(&g_slots,(__bridge const void *)a) == 1 && player_mask == 3);
    check(@"held buttons are republished only at their new players", buttons[0] == DM_BTN_A && buttons[1] == DM_BTN_B);
    check(@"haptic routes move with both controllers", rumble[0] == b && rumble[1] == a);
    check(@"both old motion sources are cleared", cleared[0] && cleared[1]);
    check(@"player indicators follow the swap", a.playerIndex == GCControllerPlayerIndex2 && b.playerIndex == GCControllerPlayerIndex1);
    NSUInteger count = writes.count;
    check(@"same-player assignment emits no releases", assign_controller(a,1) && writes.count == count);
    check(@"invalid targets emit no releases", !assign_controller(a,-1) && !assign_controller(a,DM_PLAYERS) && writes.count == count);
    __block BOOL worker_result = YES;
    dispatch_semaphore_t worker_done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ worker_result = assign_controller(a,2); dispatch_semaphore_signal(worker_done); });
    long waited = dispatch_semaphore_wait(worker_done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
    check(@"a worker cannot mutate the slot transaction", waited == 0 && !worker_result && g_held[1] == a && writes.count == count);
    check(@"moving to a free player succeeds", assign_controller(a,7));
    check(@"the vacated player releases buttons and haptics", buttons[1] == 0 && rumble[1] == nil && !g_held[1]);
    check(@"player 8 input and connection mask are published", buttons[7] == DM_BTN_B && rumble[7] == a && player_mask == 0x81);
    check(@"players beyond the four Apple indicators stay explicitly unlit", a.playerIndex == GCControllerPlayerIndexUnset);
    assign_controller(b,3);
    check(@"touch player 1 can remain available with controllers on later players", !player_one_held() && player_mask == 0x88);
    pads_slotted_now(@[b],a);
    check(@"disconnect releases the assigned player", !g_held[7] && !buttons[7] && !rumble[7] && player_mask == 8);
    GCController *reconnected = GCController.controllerWithExtendedGamepad;
    pads_slotted_now(@[b,reconnected],nil);
    check(@"reconnect uses the explicit assignment name hint", g_held[7] == reconnected && g_held[3] == b);
    pad_changed(b.extendedGamepad);
    check(@"moving a control identifies its live connection", g_last_controller == b);
    DmControllerSheet *sheet = [[DmControllerSheet alloc] initWithStyle:UITableViewStyleInsetGrouped];
    check(@"the sheet lists only assigned controllers", [sheet tableView:sheet.tableView numberOfRowsInSection:0] == 2);
    UITableViewCell *row = [sheet tableView:sheet.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    check(@"the sheet names the player and last input without a persistent ID", [row.textLabel.text isEqual:@"Player 4"] && [row.detailTextLabel.text containsString:@"last input"]);
    sheet.selectedController = b;
    check(@"every guest player is an explicit assignment choice", [sheet tableView:sheet.tableView numberOfRowsInSection:0] == DM_PLAYERS);
    row = [sheet tableView:sheet.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:7 inSection:0]];
    check(@"an occupied choice explicitly says swap", [row.detailTextLabel.text hasPrefix:@"Swap with "]);
    assignment_started();
    check(@"opening assignment releases live game input and haptics", g_assigning && !buttons[3] && !buttons[7] && !rumble[3] && !rumble[7]);
    read_pad(b.extendedGamepad);
    check(@"input stays released while the sheet owns controls", !buttons[3]);
    assign_controller(b,2); assignment_finished();
    check(@"closing restores held input at the newly assigned player", !g_assigning && buttons[2] == DM_BTN_A && buttons[3] == 0 && rumble[2] == b);
    pads_slotted_now(@[],nil); memset(&g_slots,0,sizeof g_slots);

    AssignmentController *sensor = [AssignmentController new]; sensor.vendorName = @"Synthetic motion controller";
    sensor.motion = [AssignmentMotion new]; sensor.motion.hasRotationRate = YES;
    sensor.motion.sensorsRequireManualActivation = YES; sensor.motion.acceleration = (GCAcceleration){0,0,-1};
    GCController *c = (id)sensor; pad_slot_take(&g_slots,(__bridge const void *)c,"Synthetic motion controller"); g_held[0] = c;
    pad_attach(c,0); GCMotionValueChangedHandler stale = sensor.motion.valueChangedHandler; stale((id)sensor.motion);
    check(@"synthetic motion starts at its assigned player", motion_samples == 1 && motion_player == 0 && sensor.motion.sensorsActive);
    assign_controller(c,2); unsigned samples = motion_samples;
    stale((id)sensor.motion);
    check(@"a queued old gyro callback cannot write the vacated player", motion_samples == samples);
    sensor.motion.valueChangedHandler((id)sensor.motion);
    check(@"fresh gyro data follows reassignment", motion_samples == samples + 1 && motion_player == 2);
    assign_controller(c,0); samples = motion_samples; stale((id)sensor.motion);
    check(@"an old gyro generation stays invalid after moving back", motion_samples == samples);
    pads_slotted_now(@[],nil);
    check(@"disconnect stops and clears synthetic motion", !sensor.motion.sensorsActive && !sensor.motion.valueChangedHandler && !g_held[0]);
}

@interface AssignmentScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AssignmentScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options; self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new]; [self.window makeKeyAndVisible];
    static BOOL started; if (started) return; started = YES;
    verify_assignment();
    NSInteger failed = 0; for (NSDictionary *item in checks) if (![item[@"passed"] boolValue]) failed++;
    NSDictionary *report = @{@"checks":checks,@"failed":@(failed),@"physicalControllersTested":@NO,@"UIAutomationPerformed":@NO,
        @"systemVersion":UIDevice.currentDevice.systemVersion};
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL]
        writeToURL:[documents URLByAppendingPathComponent:@"results.json"] options:NSDataWritingAtomic error:NULL];
    if (failed) { fflush(stderr); exit(1); }
}
@end
@interface AssignmentApp : UIResponder <UIApplicationDelegate>
@end
@implementation AssignmentApp
@end
int main(int argc, char **argv) { @autoreleasepool {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    freopen([[documents URLByAppendingPathComponent:@"assignment.log"] fileSystemRepresentation],"w",stderr); setvbuf(stderr,NULL,_IONBF,0);
    return UIApplicationMain(argc,argv,nil,NSStringFromClass(AssignmentApp.class));
} }
