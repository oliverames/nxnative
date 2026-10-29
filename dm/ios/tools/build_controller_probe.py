#!/usr/bin/env python3
"""Build an unsigned controller-assignment fixture with synthetic controllers.

GAME selects only source constants. No games, keys, signing, discovery, motion
sensors or device actions. Run separately on an authorized test device.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]


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
    header = include / 'game_profile.h'
    subprocess.run([sys.executable, str(REPO / 'dm/games/game.py'), 'header', game, str(header)], check=True)
    project = {
        'name': 'ControllerVerification', 'options': {'deploymentTarget': {'iOS': '26.0'}},
        'targets': {'ControllerVerification': {
            'type': 'application', 'platform': 'iOS',
            'sources': [{'path': str(REPO / 'dm/ios/tests/controller_assignment_check.m')}],
            'dependencies': [{'sdk': name + '.framework'} for name in
                             ('UIKit', 'Foundation', 'QuartzCore', 'GameController', 'CoreMotion', 'CoreText')],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.anygame.controller-verification',
                'ENABLE_DEBUG_DYLIB': 'NO', 'CODE_SIGN_STYLE': 'Automatic',
                'TARGETED_DEVICE_FAMILY': '1', 'CLANG_ENABLE_OBJC_ARC': 'YES',
                'HEADER_SEARCH_PATHS': [str(REPO / 'dm/host'), str(include)],
            }},
            'info': {'path': 'Info.plist', 'properties': {
                'CFBundleDisplayName': 'Controller Verification', 'UILaunchScreen': {},
                'UIFileSharingEnabled': True,
                'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
                    'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                        'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'AssignmentScene'}]}},
            }},
        }},
    }
    (output / 'project.yml').write_text(json.dumps(project, indent=2) + '\n')
    files = [REPO / p for p in ('dm/ios/tests/controller_assignment_check.m', 'dm/ios/Sources/DmGamepad.m',
             'dm/host/pad_slots.h', 'dm/host/dm_input.h', 'dm/host/motion_apple.h', 'dm/host/motion_fusion.h',
             'dm/host/front.h', 'dm/host/dm.h', 'dm/host/haptics_apple.h', 'dm/host/hle_haptics.h')]
    report = {'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
              'gameProfile': game, 'physicalControllersTested': False,
              'generatedProfileSHA256': hashlib.sha256(header.read_bytes()).hexdigest(),
              'sha256': {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
    (output / 'source-provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(output / 'project.yml')], check=True)
    subprocess.run(['xcodebuild', '-project', str(output / 'ControllerVerification.xcodeproj'),
                    '-scheme', 'ControllerVerification', '-configuration', 'Debug',
                    '-destination', 'generic/platform=iOS', '-derivedDataPath', str(output / 'DerivedData'),
                    '-jobs', '3', 'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
    print(output / 'DerivedData/Build/Products/Debug-iphoneos/ControllerVerification.app')


if __name__ == '__main__':
    main()
