#!/usr/bin/env python3
"""Build an unsigned native iOS scene-metrics probe with synthetic host stubs.

GAME selects only source profile constants. No game files, keys or signing are
used. Install/run the resulting app separately on an authorized test device.
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
    parser.add_argument('--external-scenes', action='store_true', help='build the programmatic external-routing probe instead of the default metrics probe')
    parser.add_argument('--destination', default='generic/platform=iOS', help='Xcode build destination; default is an unsigned device build')
    args = parser.parse_args()
    name = 'ExternalSceneVerification' if args.external_scenes else 'DisplayVerification'
    source = 'external_scene_check.m' if args.external_scenes else 'scene_metrics_check.m'
    delegate = 'ExternalPolicyScene' if args.external_scenes else 'MetricsScene'
    game = os.environ.get('GAME') or os.environ.get('DM_GAME')
    if not game:
        parser.error('GAME or DM_GAME must select a source profile')
    output = args.output.resolve()
    output.mkdir(parents=True)
    include = output / 'Include'
    include.mkdir()
    subprocess.run([sys.executable, '-B', str(REPO / 'dm/games/game.py'), 'header', game,
                    str(include / 'game_profile.h')], check=True)
    project = {
        'name': name,
        'options': {'deploymentTarget': {'iOS': '26.0'}},
        'targets': {name: {
            'type': 'application', 'platform': 'iOS',
            'sources': [{'path': str(REPO / 'dm/ios/tests' / source)}],
            'dependencies': [{'sdk': name + '.framework'} for name in
                             ('UIKit', 'Foundation', 'QuartzCore', 'Metal', 'AVFAudio', 'GameController')],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.anygame.external-scene-verification' if args.external_scenes else 'dev.anygame.display-verification',
                'ENABLE_DEBUG_DYLIB': 'NO', 'CODE_SIGN_STYLE': 'Automatic',
                'TARGETED_DEVICE_FAMILY': '1',
                'HEADER_SEARCH_PATHS': [str(REPO / 'dm/host'), str(REPO / 'dm/ios/Sources'), str(include)],
            }},
            'info': {'path': 'Info.plist', 'properties': {
                'CFBundleDisplayName': 'Display Verification', 'UILaunchScreen': {},
                'UIFileSharingEnabled': True,
                'UISupportedInterfaceOrientations': ['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
                'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
                    'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                        'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': delegate}]}},
            }},
        }},
    }
    if args.external_scenes:
        properties = project['targets'][name]['info']['properties']
        properties['DMExternalDisplayEnabled'] = True
        properties['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleExternalDisplayNonInteractive'] = [{
            'UISceneConfigurationName': 'External game display', 'UISceneDelegateClassName': 'DmExternalSceneDelegate'}]
    paths = ['dm/ios/tests/' + source, 'dm/ios/Sources/front_ios.m', 'dm/ios/Sources/DmSceneRouting.h']
    if args.external_scenes:
        paths.append('dm/ios/Sources/main.m')
    provenance = {
        'commit': subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
        'sourceSHA256': {path: hashlib.sha256((REPO / path).read_bytes()).hexdigest() for path in paths},
        'gameProfile': game,
    }
    provenance_file = output / 'SourceProvenance.json'
    provenance_file.write_text(json.dumps(provenance, indent=2) + '\n')
    project['targets'][name]['sources'].append({'path': str(provenance_file), 'buildPhase': 'resources'})
    spec = output / 'project.yml'
    spec.write_text(json.dumps(project, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(spec)], check=True)
    subprocess.run(['xcodebuild', '-project', str(output / f'{name}.xcodeproj'),
                    '-scheme', name, '-configuration', 'Debug',
                    '-destination', args.destination, '-derivedDataPath', str(output / 'DerivedData'),
                    '-jobs', '3', 'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
    print(output / 'DerivedData/Build/Products' / ('Debug-iphonesimulator' if 'Simulator' in args.destination else 'Debug-iphoneos') / f'{name}.app')


if __name__ == '__main__':
    main()
