// Native GPU readback of production presentation code; no game or HDR display claim.
#import <UIKit/UIKit.h>
#define main dm_edr_test_main
#include "../../gfx/tests/t_edr_present.m"
#undef main

@interface EDRScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation EDRScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];
    static BOOL started;
    if (started) return;
    started = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = dm_edr_test_main();
        NSDictionary *report = @{@"checks":@(checks), @"failed":@(failed), @"exitStatus":@(status),
            @"syntheticHeadroom":@YES, @"physicalHDRDisplayTested":@NO,
            @"systemVersion":UIDevice.currentDevice.systemVersion,
            @"metalDevice":g_dev.name ?: @"unavailable"};
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL]
            writeToURL:[documents URLByAppendingPathComponent:@"results.json"] options:NSDataWritingAtomic error:NULL];
        fflush(stdout); fflush(stderr);
        if (status) exit(status);
    });
}
@end
@interface EDRApp : UIResponder <UIApplicationDelegate>
@end
@implementation EDRApp
@end
int main(int argc, char **argv) { @autoreleasepool {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    freopen([[documents URLByAppendingPathComponent:@"gpu.log"] fileSystemRepresentation], "w", stdout);
    dup2(fileno(stdout), fileno(stderr)); setvbuf(stdout,NULL,_IONBF,0);
    return UIApplicationMain(argc,argv,nil,NSStringFromClass(EDRApp.class));
} }
