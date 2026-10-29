// Programmatic routing/policy probe of the complete production iOS front end.
// Output windows share one real phone scene. Distinct identities below model
// external scene events; this is not a physical external-display test.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include <stdatomic.h>
#include <time.h>
#include "../Sources/front_ios.m"
#define main unused_production_main
#include "../Sources/main.m"
#undef main

static _Atomic int guest_starts;
static NSMutableArray *trace;
static int last_focus, frozen, link_paused;
uint64_t g_t0_ns;
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
int dm_main(int argc, char **argv) { (void)argc; (void)argv; atomic_fetch_add(&guest_starts, 1); return 0; }
void dm_host_preload_start(int argc, char **argv) { (void)argc; (void)argv; }
void dm_haptics_apple_init(void) {}
UIView *dm_gamepad_view(CGRect frame) { return [[UIView alloc] initWithFrame:frame]; }
void dm_gamepad_reset(void) {}
void dm_gamepad_active(void) {}
bool dm_show_launcher(void *view, void (*done)(void)) { (void)view; (void)done; return false; }
uint64_t mtl_present_count(void) { return 0; }
void dm_audio_suspend(int on) { (void)on; }
void dm_audio_reset(void) {}
void dm_focus_set(int state) { last_focus = state; }
void guest_clock_freeze_for(int reason, int on) { (void)reason; frozen = on; }
void dm_gfx_suspend(int on) { [trace addObject:on ? @"gate close" : @"gate open"]; }
void mtl_link_pause(int on) { link_paused = on; [trace addObject:on ? @"link pause" : @"link resume"]; }

static NSMutableArray *checks;
static void check(NSString *name, BOOL passed) {
    [checks addObject:@{@"name":name, @"passed":@(passed)}];
    fprintf(stderr, "[external] %s: %s\n", name.UTF8String, passed ? "PASS" : "FAIL");
}
static void checkMove(NSString *name) {
    check(name, [trace isEqualToArray:@[@"gate close", @"link pause", @"link resume", @"gate open"]]);
    if (trace.count) fprintf(stderr, "[external] handover trace: %s\n", trace.description.UTF8String);
    [trace removeAllObjects];
}
@interface ExternalPolicyScene : SceneDelegate
@end
@implementation ExternalPolicyScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    g_boot_ok = 0;
    [super scene:scene willConnectToSession:session options:options];
    DmRootVC *root = (DmRootVC *)self.window.rootViewController; root.launched = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        checks = [NSMutableArray array]; trace = [NSMutableArray array];
        UIWindowScene *phone = (UIWindowScene *)scene;
        check(@"this app explicitly opts into external routing", front_ios_external_enabled());
        front_ios_scene_event(phone, 3);
        g_boot_ok = 1; [root startGame];
        void *layer = front_metal_layer(); DmGameView *game = root.game;
        [root startGame];
        check(@"starting again retains the single game view and layer", root.game == game && front_metal_layer() == layer);
        if (@available(iOS 27.0, *)) check(@"iOS 27 registers an accessory on the owning controller", root.externalAccessory != nil);
        check(@"reconnecting the phone reuses its runtime owner", front_ios_root() == root);
        [trace removeAllObjects];

        // NSObject supplies only weak identity/hash semantics; no fake UIKit
        // lifecycle or screen API is invoked on it. All event processing and
        // view moves run through the production functions.
        UIWindowScene *identity = (UIWindowScene *)[NSObject new];
        DmExternalRootVC *external = (DmExternalRootVC *)front_ios_external_root(identity);
        UIWindow *output = [[UIWindow alloc] initWithWindowScene:phone];
        output.rootViewController = external; output.hidden = NO;
        front_ios_scene_event(identity, 2);
        checkMove(@"external connection drains and pauses before moving, then resumes");
        check(@"external connection transfers the same render view", game.superview == external.view && front_metal_layer() == layer);
        check(@"phone retains its controls and FPS label", root.pad.superview == root.view && (!root.fps || root.fps.superview == root.view));
        check(@"the noninteractive output does not take the key window", self.window.isKeyWindow && !output.isKeyWindow);
        check(@"an external scene never creates a second guest view", external.view.subviews.count >= 1 && root.game == game);
        front_ios_scene_event(identity, 0);
        check(@"external resign-active cannot suspend an active phone", trace.count == 0 && last_focus == 1 && !frozen);
        front_ios_scene_event(identity, 1);
        checkMove(@"background output falls back to phone with a fenced handover");
        check(@"fallback retains the layer and phone render target", game.superview == root.view && front_metal_layer() == layer);

        front_ios_scene_event(identity, 3); [trace removeAllObjects];
        front_ios_scene_event(phone, 1);
        check(@"active external scene keeps the shared runtime alive when phone backgrounds", trace.count == 0 && last_focus == 1 && !frozen);
        front_ios_scene_event(identity, 0);
        check(@"visible inactive scenes lose input focus without suspending graphics", trace.count == 0 && last_focus == 2 && !frozen);
        front_ios_scene_event(identity, 1);
        check(@"all-background closes graphics and freezes the guest", [trace isEqualToArray:@[@"gate close", @"link pause"]] && frozen && g_route_suspended);
        check(@"all-background fallback keeps the same retained layer", game.superview == root.view && front_metal_layer() == layer);
        [trace removeAllObjects]; front_ios_external_disconnect(external); front_ios_scene_event(identity, 5);
        check(@"disconnect while backgrounded does not reopen graphics", trace.count == 0 && g_route_suspended && frozen);
        front_ios_scene_event(phone, 2);
        check(@"foreground return resumes a link paused during fallback", !link_paused && !g_route_suspended && !frozen && last_focus == 2);
        check(@"foreground return resumes the link before reopening the graphics gate", [trace isEqualToArray:@[@"link resume", @"gate open"]]);
        front_ios_scene_event(phone, 3); [trace removeAllObjects];

        external = (DmExternalRootVC *)front_ios_external_root(identity); output.rootViewController = external;
        front_ios_scene_event(identity, 3); [trace removeAllObjects];
        front_ios_external_disconnect(external); front_ios_scene_event(identity, 5); output.hidden = YES;
        checkMove(@"active unplug fences the move back to the phone");
        check(@"unplug retains all phone controls and the one Metal layer", game.superview == root.view && root.pad.superview == root.view && front_metal_layer() == layer);
        check(@"unplug leaves the phone active and the guest clock running", last_focus == 1 && !frozen && !g_route_suspended);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            check(@"all scene changes started only one guest runtime", atomic_load(&guest_starts) == 1);
            NSInteger failed = 0; for (NSDictionary *item in checks) if (![item[@"passed"] boolValue]) failed++;
            NSURL *provenanceURL = [NSBundle.mainBundle URLForResource:@"SourceProvenance" withExtension:@"json"];
            NSDictionary *provenance = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:provenanceURL] options:0 error:NULL];
            NSDictionary *report = @{@"sourceProvenance":provenance, @"checks":checks, @"failed":@(failed), @"guestStarts":@(atomic_load(&guest_starts)),
                @"physicalExternalDisplayTested":@NO, @"outputWindowsSharePhoneScene":@YES,
                @"externalSceneIdentitiesInjected":@YES, @"graphicsGateAndDisplayLinkStubbed":@YES,
                @"systemVersion":UIDevice.currentDevice.systemVersion};
            NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL]
                writeToURL:[documents URLByAppendingPathComponent:@"results.json"] options:NSDataWritingAtomic error:NULL];
        });
    });
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
        freopen([[documents URLByAppendingPathComponent:@"external.log"] fileSystemRepresentation], "w", stderr); setvbuf(stderr, NULL, _IOLBF, 0);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class));
    }
}
