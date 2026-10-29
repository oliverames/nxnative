// iOS front end (the iOS implementation of front.h): a centered 16:9 Metal view (black bars on both sides) + a full-screen virtual gamepad layer (DmGamepad.m, controls drawn over the picture).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#include <errno.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "haptics_apple.h"
#import "DmSceneRouting.h"

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
void dm_gamepad_active(void);
void front_ios_boot(void);
int front_ios_boot_ok(void);
const char *front_ios_boot_message(void);   // main.m: why a build that keeps the game files off the IPA found none usable (NULL = the generic hint)
bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0)

static CAMetalLayer *g_layer;
static NSMapTable<UIWindowScene *, NSNumber *> *g_scene_focus;
static NSHashTable<UIViewController *> *g_external_roots;
static __weak UIViewController *g_external_output;
static int g_route_focus = 3;
static BOOL g_route_runtime_started, g_route_suspended;
static void external_refresh(void);
static void external_register(UIViewController *controller);
void front_ios_focus_event(int event);
void mtl_link_pause(int on);
int front_ios_external_enabled(void) { return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMExternalDisplayEnabled"] boolValue]; }
static CGRect fit_game(CGRect bounds) {
    CGFloat w = bounds.size.width, h = bounds.size.height;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    return CGRectMake(floor((bounds.size.width - w) / 2), floor((bounds.size.height - h) / 2), w, h);
}
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);

// UIKit values belong to the scene rendering this view, not the phone's main
// screen. Publish one snapshot on the main thread; the present thread only
// reads the copy (front_screen_max_fps), including while a scene moves displays.
typedef struct {
    double scale, width, height, headroom, potential_headroom;
    int max_fps, headroom_active;
} DmDisplayMetrics;
static pthread_mutex_t g_display_mu = PTHREAD_MUTEX_INITIALIZER;
static DmDisplayMetrics g_display;
static DmDisplayMetrics display_snapshot(void) {
    pthread_mutex_lock(&g_display_mu); DmDisplayMetrics value = g_display; pthread_mutex_unlock(&g_display_mu);
    return value;
}
int front_screen_max_fps(void) { return display_snapshot().max_fps; }

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
        [self registerForTraitChanges:@[UITraitDisplayScale.class, UITraitHDRHeadroomUsageLimit.class]
            withHandler:^(DmGameView *view, UITraitCollection *previous) { (void)previous; [view setNeedsLayout]; }];
        for (NSNotificationName name in @[UIScreenBrightnessDidChangeNotification, UIScreenModeDidChangeNotification])
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(displayChanged:) name:name object:nil];
    }
    return self;
}
- (void)didMoveToWindow { [super didMoveToWindow]; [self setNeedsLayout]; }
- (void)displayChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object == self.window.windowScene.screen) [self setNeedsLayout];
    });
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *scene = self.window.windowScene;
    if (!scene) return;   // No display is selected until the view joins a window.
    UIScreen *screen = scene.screen;
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.contentsScale = screen.nativeScale;
    // A fitted view can have fractional points. CAMetalLayer normalizes its
    // drawable to whole pixels, so choose that size once and publish the actual
    // post-set value rather than repeatedly requesting a fractional size.
    CGSize pixels = CGSizeMake(round(self.bounds.size.width * l.contentsScale), round(self.bounds.size.height * l.contentsScale));
    if (!CGSizeEqualToSize(l.drawableSize, pixels)) l.drawableSize = pixels;
    pixels = l.drawableSize;
    DmDisplayMetrics value = {l.contentsScale, pixels.width, pixels.height, screen.currentEDRHeadroom,
        screen.potentialEDRHeadroom, (int)screen.maximumFramesPerSecond,
        self.traitCollection.hdrHeadroomUsageLimit == UIHDRHeadroomUsageLimitActive};
    pthread_mutex_lock(&g_display_mu);
    DmDisplayMetrics previous = g_display; g_display = value;
    pthread_mutex_unlock(&g_display_mu);
    if (value.scale != previous.scale || value.width != previous.width || value.height != previous.height ||
        value.max_fps != previous.max_fps || value.headroom != previous.headroom ||
        value.potential_headroom != previous.potential_headroom || value.headroom_active != previous.headroom_active)
        LOG("display: scene scale %.3f, drawable %.0fx%.0f, maximum %d Hz, EDR headroom %.3f / %.3f (%s); SDR output",
            value.scale, value.width, value.height, value.max_fps, value.headroom, value.potential_headroom,
            value.headroom_active ? "active" : "inactive");
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UILabel *fps;
@property (nonatomic) BOOL launched;
@property (nonatomic, strong) id externalAccessory;
@property (nonatomic, strong) UILabel *externalNote;
- (void)startGame;
@end
static DmRootVC *g_root;
static void launcher_done(void) { [g_root startGame]; }
@implementation DmRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    front_ios_power_watch();
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        const char *why = front_ios_boot_message();
        lb.text = why ? [NSString stringWithFormat:@"Game files unusable.\n%s", why] : @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart.";
        [self.view addSubview:lb]; return;
    }
    front_ios_audio_watch();
}
// The game view, the pad and the frame-rate counter are made once the launcher has set the switches they read (DM_SHOW_FPS, DM_METAL_HUD); the host's loading began at app launch (main.m)
- (void)startGame {
    if (self.game) return;
    front_hud_env();   // before the game view makes its device (an env file's DM_METAL_HUD sets it in main.m already)
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
    dm_haptics_apple_init();
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    self.fps = front_ios_fps_label();   // above the pad, which hides while a controller is connected
    if (self.fps) [self.view addSubview:self.fps];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    if (front_ios_external_enabled()) { external_register(self); external_refresh(); }
    front_ios_boot();
    g_route_runtime_started = YES;
    if (front_ios_external_enabled()) external_refresh();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; if (!self.game) return;
    if (self.game.superview == self.view) self.game.frame = fit_game(b);
    self.externalNote.frame = b;
    if (self.fps) {   // the top row's free stretch: right of DmGamepad.m's L3 key (102 + 17 of its units from the safe edge), level with − / + (22 units down); u is its unit
        CGRect s = UIEdgeInsetsInsetRect(b, self.view.safeAreaInsets); CGFloat u = MIN(b.size.height / 430.0, 1.3);
        self.fps.frame = CGRectMake(floor(CGRectGetMinX(s) + 130 * u), floor(CGRectGetMinY(s) + 22 * u - 11), 64, 22);
    }
}
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a];
    if (!front_ios_boot_ok() && front_ios_boot_message() && !self.presentedViewController) {   // a slim build whose game file image is missing or another version (main.m)
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Game files" message:@(front_ios_boot_message()) preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
    if (self.launched || !front_ios_boot_ok()) return;
    self.launched = YES; g_root = self;
    if (!dm_show_launcher((__bridge void *)self, launcher_done)) [self startGame];   // the settings screen first (Launcher.swift), when the app has one
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
UIViewController *front_ios_root(void) {
    if (!front_ios_external_enabled()) return [DmRootVC new];
    // Reconnecting the primary scene reuses its controls, Metal layer and guest.
    if (!g_root) g_root = [DmRootVC new];
    return g_root;
}

@interface DmExternalRootVC : UIViewController
@property (nonatomic, weak) UIWindowScene *scene;
@property (nonatomic, strong) UILabel *hint;
@end
@implementation DmExternalRootVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    self.hint = [[UILabel alloc] initWithFrame:self.view.bounds];
    self.hint.text = @"Start the game on your iPhone"; self.hint.textAlignment = NSTextAlignmentCenter;
    self.hint.textColor = UIColor.whiteColor; self.hint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.hint];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (g_root.game.superview == self.view) g_root.game.frame = fit_game(self.view.bounds);
    self.hint.hidden = g_root.game.superview == self.view;
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

static int scene_focus(UIWindowScene *scene) { return scene ? ([g_scene_focus objectForKey:scene] ?: @3).intValue : 3; }
static void external_register(UIViewController *controller) {
    if (@available(iOS 27.0, *)) {
        DmRootVC *root = (DmRootVC *)controller; if (root.externalAccessory) return;
        UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"External game display" sessionRole:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
        configuration.delegateClass = NSClassFromString(@"DmExternalSceneDelegate");
        root.externalAccessory = [root registerSceneAccessory:[UISceneAccessory externalNonInteractiveSceneAccessoryWithConfiguration:configuration]];
    }
}
UIViewController *front_ios_external_root(UIWindowScene *scene) {
    DmExternalRootVC *root = [DmExternalRootVC new]; root.scene = scene;
    if (!g_external_roots) g_external_roots = [NSHashTable weakObjectsHashTable];
    [g_external_roots addObject:root];
    return root;
}
void front_ios_external_disconnect(UIViewController *controller) {
    [g_external_roots removeObject:controller];
    if (g_external_output == controller) g_external_output = nil;
    external_refresh();
}
static void external_refresh(void) {
    if (!front_ios_external_enabled() || !g_root.game) return;
    int desired = scene_focus(g_root.view.window.windowScene);
    DmExternalRootVC *target = (DmExternalRootVC *)g_external_output;
    if (target && (![g_external_roots containsObject:target] || scene_focus(target.scene) == 3)) target = nil;
    for (DmExternalRootVC *root in g_external_roots) {
        int focus = scene_focus(root.scene); if (focus < desired) desired = focus;
        if (!target && focus != 3) target = root;
    }
    UIView *host = target ? target.view : g_root.view;
    BOOL moving = g_root.game.superview != host;
    // The phone retains the pad and FPS label. The very same Metal view/layer
    // changes parent, so the renderer never observes a replacement layer or a
    // second guest. Stop submissions and drain their output before that move.
    if (desired == 3 && g_route_runtime_started && !g_route_suspended) {
        front_ios_focus_event(1); g_route_suspended = YES;
    }
    BOOL fenced = moving && g_route_runtime_started && !g_route_suspended;
    if (fenced) dm_gfx_suspend(1);
    if (moving && g_route_runtime_started) mtl_link_pause(1);
    if (moving) {
        [g_root.game removeFromSuperview]; [host insertSubview:g_root.game atIndex:0];
        [host setNeedsLayout]; [host layoutIfNeeded];
        if (target) [target viewDidLayoutSubviews]; else [g_root viewDidLayoutSubviews];
        [g_root.game setNeedsLayout]; [g_root.game layoutIfNeeded];
        LOG("external display: render layer moved to %s; phone controls retained", target ? "external scene" : "primary scene");
    }
    g_external_output = target;
    if (target && !g_root.externalNote) {
        g_root.externalNote = [[UILabel alloc] initWithFrame:g_root.view.bounds];
        g_root.externalNote.text = @"Playing on your external display"; g_root.externalNote.textAlignment = NSTextAlignmentCenter;
        g_root.externalNote.textColor = UIColor.secondaryLabelColor;
        g_root.externalNote.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [g_root.view insertSubview:g_root.externalNote atIndex:0];
    }
    g_root.externalNote.hidden = !target;
    if (desired != 3) {
        if (g_route_runtime_started && (moving || g_route_suspended)) mtl_link_pause(0);
        if (g_route_suspended || g_route_focus == 3) { front_ios_focus_event(2); g_route_suspended = NO; }
        else if (fenced) dm_gfx_suspend(0);
        if (desired != g_route_focus) front_ios_focus_event(desired == 1 ? 3 : 0);
    }
    g_route_focus = desired;
}
void front_ios_scene_event(UIWindowScene *scene, int event) {
    if (!front_ios_external_enabled()) { if (event < 4) front_ios_focus_event(event); return; }
    if (!g_scene_focus) g_scene_focus = [NSMapTable weakToStrongObjectsMapTable];
    if (event == 5) [g_scene_focus removeObjectForKey:scene];
    else {
        int focus = event == 1 ? 3 : event == 3 ? 1 : 2;
        if (event == 4) focus = scene.activationState == UISceneActivationStateForegroundActive ? 1 : scene.activationState == UISceneActivationStateForegroundInactive ? 2 : 3;
        [g_scene_focus setObject:@(focus) forKey:scene];
    }
    external_refresh();
}
void front_ios_scene_changed(UIWindowScene *scene) {
    if (g_root.game.window.windowScene != scene) return;
    [g_root.game setNeedsLayout]; [g_root.game layoutIfNeeded];
}

// Thermal state and screen brightness for the power and present rows every 300 frames (hle_nvn.c; its weak defaults return -1 on the Mac). thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
// Brightness is read on the main thread at start and on each change; every change of the thermal state and of Low Power Mode (which lowers the CPU clock) is logged with the time since launch
static _Atomic double g_brightness = -1;
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }   // the frame step does not probe in it (hle_nvn.c fstep_cpu_slowed)
double dm_brightness_now(void) { return g_brightness; }
static void front_ios_power_watch(void) {
    g_brightness = UIScreen.mainScreen.brightness;
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; g_brightness = UIScreen.mainScreen.brightness; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9); }];
    LOG("front end: thermal state %d, brightness %.2f, Low Power Mode %s", dm_thermal_now(), g_brightness, dm_low_power_now() ? "on" : "off");
}

// Frame-rate counter: the frames put on screen in the last second (nvn_mtl.m counts them for NVN and for the Vulkan layer alike; frames the display link merged away are not counted).
// On when the IPA was built with it (the NSP script's SHOW_FPS / --show-fps → DMShowFPS in Info.plist); DM_SHOW_FPS=0 / 1 in Documents/env.txt overrides that without a rebuild. NULL when off
uint64_t mtl_present_count(void);
static UILabel *front_ios_fps_label(void) {
    const char *e = getenv("DM_SHOW_FPS");
    if (!(e ? atoi(e) != 0 : [[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMShowFPS"] boolValue])) return nil;
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold]; l.textColor = UIColor.whiteColor; l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; l.layer.cornerRadius = 6; l.layer.masksToBounds = YES; l.userInteractionEnabled = NO;
    l.text = @"-- fps";
    __block uint64_t n0 = mtl_present_count(); __block double t0 = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t; uint64_t n = mtl_present_count(); double now = CACurrentMediaTime();
        if (now - t0 < 1.5) l.text = [NSString stringWithFormat:@"%.0f fps", (n - n0) / (now - t0)];   // a longer span is the time in the background: no reading
        n0 = n; t0 = now;
    }];
    LOG("front end: frame-rate counter on");
    return l;
}

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's view and the pad, the title, a bar and a count, centered; UIKit views, so it draws while the game's thread waits
static UIView *g_prog; static UILabel *g_prog_count; static UIProgressView *g_prog_bar; static UILabel *g_prog_title;
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            UIView *root = g_root.view; if (!root) return;
            g_prog = [[UIView alloc] initWithFrame:root.bounds]; g_prog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            g_prog.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(floor((root.bounds.size.width - 320) / 2), floor((root.bounds.size.height - 96) / 2), 320, 96)];
            box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            g_prog_title = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 320, 30)]; g_prog_title.textAlignment = NSTextAlignmentCenter; g_prog_title.textColor = UIColor.whiteColor;
            g_prog_title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
            g_prog_bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; g_prog_bar.frame = CGRectMake(20, 48, 280, 4);
            g_prog_count = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 320, 22)]; g_prog_count.textAlignment = NSTextAlignmentCenter;
            g_prog_count.textColor = [UIColor colorWithWhite:0.72 alpha:1]; g_prog_count.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [root addSubview:g_prog];
        }
        g_prog_title.text = tt; g_prog_bar.progress = total > 0 ? (float)done / (float)total : 0;
        g_prog_count.text = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                             [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}
void *front_metal_layer(void) { return (__bridge void *)g_layer; }
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    // The guest clock keeps running meanwhile, as on the Switch (hle_swkbd.c): a freeze here as well stopped Octopath Traveler 0's frame loop for as long as the box was up and made its sound stutter
    // (4,977 ms and 2,577 ms frames, 5,181 wakeups a second). The inline keyboard freezes around its own call (hle_swkbd.c)
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game. hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("front end: save data write failed errno=%d, telling the player", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("[RED] front end: no window for the save-failure alert errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"Storage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"Saving failed (errno %d); progress was not saved.", err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category is Playback, as a game's or media app's: the ring / silent switch does not mute it (the default SoloAmbient follows the switch, which silenced the game whenever the phone was on silent) and it still interrupts other apps' audio.
// Set once at boot and again on return to the foreground (the system may reset it after an interruption)
static int g_session_off;   // the last activation failed (another app or a call still held the session): tried again when the app becomes active
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategoryPlayback error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    LOG("audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for 5 ms)", s.sampleRate, s.IOBufferDuration * 1000);
}

// Real audio output is suspended (the silent sink paces the game) while the app is in the background or another audio session has interrupted ours (Siri, an alarm, a call).
// Without the interruption observer the AudioUnits stayed "started" while iOS no longer called them, and a game waiting for its buffers back lost its sound until restart.
// All of this runs on the main queue, like the scene callbacks
static int g_audio_bg, g_audio_intr;
static void front_ios_audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
static void front_ios_audio_watch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue], reason = [n.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) { LOG("audio session: interrupted (reason %lu)", (unsigned long)reason); g_audio_intr = 1; }
        else {
            LOG("audio session: interruption ended"); g_audio_intr = 0;
            if (!g_audio_bg) front_ios_audio_session();
        }
        front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; LOG("audio session: the media services were reset; setting the session and the outputs up again");
        front_ios_audio_session(); dm_audio_reset();
    }];
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed).
// The screen stays on while the game is active: only touches reset the idle timer, so with a controller (or during a cutscene) the screen dimmed and locked mid-game
void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); break;
        case 3:   // Becoming active again also ends an interruption whose "ended" never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); dm_gamepad_active(); dm_focus_set(1); break;
    }
}
