// Exercise the production notification observer with deterministic activation
// responses. Actual CarPlay/USB/Bluetooth routes are deliberately not simulated.
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <GameController/GameController.h>
#include <stdatomic.h>
#include <time.h>
static int activations, resets;
static BOOL activationFails;
@interface ProbeAudioSession : NSObject
+ (instancetype)sharedInstance;
- (BOOL)setCategory:(NSString *)category error:(NSError **)error;
- (BOOL)setPreferredSampleRate:(double)value error:(NSError **)error;
- (BOOL)setPreferredIOBufferDuration:(double)value error:(NSError **)error;
- (BOOL)setActive:(BOOL)value error:(NSError **)error;
@property(readonly) double sampleRate;
@property(readonly) double IOBufferDuration;
@property(readonly) AVAudioSessionRouteDescription *currentRoute;
@end
@implementation ProbeAudioSession
+ (instancetype)sharedInstance { static ProbeAudioSession *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
- (BOOL)setCategory:(NSString *)category error:(NSError **)error { (void)category; (void)error; return YES; }
- (BOOL)setPreferredSampleRate:(double)value error:(NSError **)error { (void)value; (void)error; return YES; }
- (BOOL)setPreferredIOBufferDuration:(double)value error:(NSError **)error { (void)value; (void)error; return YES; }
- (BOOL)setActive:(BOOL)value error:(NSError **)error { (void)value; activations++; if (activationFails && error) *error = [NSError errorWithDomain:@"verification" code:1 userInfo:nil]; return !activationFails; }
- (double)sampleRate { return 48000; }
- (double)IOBufferDuration { return .005; }
- (AVAudioSessionRouteDescription *)currentRoute { return nil; }
@end
#define AVAudioSession ProbeAudioSession
#include "../Sources/front_ios.m"
#undef AVAudioSession
#define main unused_production_main
#include "../Sources/main.m"
#undef main
uint64_t g_t0_ns;
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
int dm_main(int argc, char **argv) { (void)argc; (void)argv; return 0; }
void dm_host_preload_start(int argc, char **argv) { (void)argc; (void)argv; }
void dm_haptics_apple_init(void) {}
UIView *dm_gamepad_view(CGRect f) { return [[UIView alloc] initWithFrame:f]; }
void dm_gamepad_reset(void) {}
bool dm_show_launcher(void *v, void (*d)(void)) { (void)v; (void)d; return false; }
uint64_t mtl_present_count(void) { return 0; }
void dm_audio_suspend(int on) { (void)on; }
void dm_audio_reset(void) { resets++; }
void dm_focus_set(int st) { (void)st; }
void guest_clock_freeze_for(int r, int on) { (void)r; (void)on; }
void dm_gfx_suspend(int on) { (void)on; }
static NSMutableArray *checks;
static void check(NSString *name, BOOL passed) { [checks addObject:@{@"name":name,@"passed":@(passed)}]; fprintf(stderr,"%s: %s\n",name.UTF8String,passed?"PASS":"FAIL"); }
static void route(unsigned reason) { [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionRouteChangeNotification object:nil userInfo:@{AVAudioSessionRouteChangeReasonKey:@(reason)}]; }
static void runChecks(void) {
    checks = [NSMutableArray array];
    unsetenv("DM_IOS_AUDIO_ROUTE_RECOVERY"); front_ios_audio_watch(); g_session_off=1; route(1);
    check(@"default off leaves route behavior unchanged",activations==0 && resets==0 && g_session_off);
    setenv("DM_IOS_AUDIO_ROUTE_RECOVERY","1",1); front_ios_audio_watch();
    route(1); check(@"failed foreground session reactivates and rebuilds outputs",activations==1 && resets==1 && !g_session_off);
    route(2); check(@"healthy route change leaves RemoteIO handling intact",activations==1 && resets==1);
    g_session_off=1; route(3); check(@"own category notification cannot recurse",activations==1 && resets==1);
    route(0); route(99); check(@"unknown reasons do not invent recovery",activations==1);
    g_audio_bg=1; route(1); check(@"background does not activate audio",activations==1);
    g_audio_bg=0; g_audio_intr=1; route(1); check(@"interrupted session does not activate audio",activations==1);
    g_audio_intr=0; activationFails=YES; route(8);
    check(@"failed recovery stays failed without resetting outputs",activations==2 && resets==1 && g_session_off);
    activationFails=NO; route(8);
    check(@"later route event can recover without foreground cycling",activations==3 && resets==2 && !g_session_off);
    NSUInteger failed=0; for (NSDictionary *c in checks) failed += ![c[@"passed"] boolValue];
    NSDictionary *report=@{@"checks":checks,@"failed":@(failed),@"physicalAudioRouteTested":@NO,@"productionAudioObserverUsed":@YES,@"nativeActivationMocked":@YES,@"systemVersion":UIDevice.currentDevice.systemVersion};
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[docs URLByAppendingPathComponent:@"results.json"] atomically:YES];
}
@interface AudioRouteScene : NSObject<UIWindowSceneDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation AudioRouteScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc=[UIViewController new]; self.window.rootViewController=vc; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{ runChecks(); });
}
@end
@interface AudioRouteApp : UIResponder<UIApplicationDelegate>
@end
@implementation AudioRouteApp
@end
int main(int argc,char **argv) { @autoreleasepool {
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    freopen([docs URLByAppendingPathComponent:@"audio.log"].fileSystemRepresentation,"w",stderr); setvbuf(stderr,NULL,_IOLBF,0);
    return UIApplicationMain(argc,argv,nil,NSStringFromClass(AudioRouteApp.class));
} }
