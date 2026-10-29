#!/usr/bin/env python3
"""Build an unsigned native iOS probe of actual registered diagnostic hooks.

GAME selects a known source profile. No game files, keys or signing are used.
Install and run only through the user's authorized device workflow.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
NAME = 'LdnTraceVerification'
KIND = 'ldn'
PRODUCTION = ['dm/host/hle_offline.c', 'dm/host/hle_net.c']
EXTRA = ['dm/host/hle_net.c']
HOST = r'''#import <UIKit/UIKit.h>
extern int dm_trace_test_main(void);
@interface TraceScene : NSObject<UIWindowSceneDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation TraceScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new]; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        int result = dm_trace_test_main();
        NSURL *url = [NSBundle.mainBundle URLForResource:@"SourceProvenance" withExtension:@"json"];
        NSDictionary *source = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:NULL];
        NSDictionary *report = @{@"status":@(result), @"registeredProductionHooksUsed":@YES,
            @"eventBindingStubbed":@YES, @"gameRuntimeUsed":@NO, @"physicalNetworkOrCameraTested":@NO,
            @"systemVersion":UIDevice.currentDevice.systemVersion, @"sourceProvenance":source};
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL]
            writeToURL:[documents URLByAppendingPathComponent:@"results.json"] atomically:YES];
        fflush(stdout); fflush(stderr);
    });
}
@end
@interface TraceApp : UIResponder<UIApplicationDelegate>
@end
@implementation TraceApp
@end
int main(int argc, char **argv) { @autoreleasepool {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    freopen([documents URLByAppendingPathComponent:@"verification.log"].fileSystemRepresentation, "w", stdout);
    freopen([documents URLByAppendingPathComponent:@"errors.log"].fileSystemRepresentation, "w", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stderr, NULL, _IOLBF, 0);
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(TraceApp.class));
} }
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='new scratch directory')
    args = parser.parse_args()
    game = os.environ.get('GAME') or os.environ.get('DM_GAME')
    if not game:
        parser.error('GAME or DM_GAME must select a source profile')
    output = args.output.resolve()
    output.mkdir(parents=True)
    include = output / 'Include'
    include.mkdir()
    subprocess.run([sys.executable, '-B', str(REPO / 'dm/games/game.py'), 'header', game,
                    str(include / 'game_profile.h')], check=True)
    (output / 'Host.m').write_text(HOST)
    test = f'dm/host/tests/t_{KIND}_trace.c'
    provenance = {'commit': subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
                  'sourceSHA256': {path: hashlib.sha256((REPO / path).read_bytes()).hexdigest()
                                   for path in [test, *PRODUCTION]}, 'gameProfile': game}
    provenance_file = output / 'SourceProvenance.json'
    provenance_file.write_text(json.dumps(provenance, indent=2) + '\n')
    project = {'name': NAME, 'options': {'deploymentTarget': {'iOS': '26.0'}}, 'targets': {NAME: {
        'type': 'application', 'platform': 'iOS',
        'sources': [{'path': str(output / 'Host.m')},
                    {'path': str(REPO / test), 'compilerFlags': '-Dmain=dm_trace_test_main'},
                    *[{'path': str(REPO / path)} for path in EXTRA],
                    {'path': str(provenance_file), 'buildPhase': 'resources'}],
        'dependencies': [{'sdk': 'UIKit.framework'}, {'sdk': 'Foundation.framework'}],
        'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': f'dev.anygame.{KIND}-trace-verification',
                             'ENABLE_DEBUG_DYLIB': 'NO', 'CODE_SIGN_STYLE': 'Automatic',
                             'TARGETED_DEVICE_FAMILY': '1', 'HEADER_SEARCH_PATHS': [str(REPO / 'dm/host'), str(include)]}},
        'info': {'path': 'Info.plist', 'properties': {
            'CFBundleDisplayName': NAME, 'UILaunchScreen': {}, 'UIFileSharingEnabled': True,
            'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {
                'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'TraceScene'}]}}}}}}}
    spec = output / 'project.yml'
    spec.write_text(json.dumps(project, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(spec)], check=True)
    subprocess.run(['xcodebuild', '-project', str(output / f'{NAME}.xcodeproj'), '-scheme', NAME,
                    '-configuration', 'Debug', '-destination', 'generic/platform=iOS',
                    '-derivedDataPath', str(output / 'DerivedData'), '-jobs', '3',
                    'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
    print(output / f'DerivedData/Build/Products/Debug-iphoneos/{NAME}.app')


if __name__ == '__main__':
    main()
