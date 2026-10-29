#!/usr/bin/env python3
"""Build an unsigned native GPU EDR-conversion probe using production shaders.

GAME selects only source constants. No games, keys, signing or device actions.
The app tests synthetic headroom and readback, not physical HDR luminance.
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
    subprocess.run([sys.executable, str(REPO / 'dm/games/game.py'), 'header', game,
                    str(include / 'game_profile.h')], check=True)
    gfx = REPO / 'dm/gfx'
    sources = [REPO / p for p in ('dm/ios/tests/edr_gpu_check.m',
               'dm/gfx/tests/edr_probe_host.c', 'dm/gfx/tests/t_host_stubs.c',
               'dm/host/crash.c', 'dm/host/hle_bigstack.c')]
    # The fixture includes nvn_mtl.m so it can exercise the actual present pass.
    sources += sorted(p for folder in ('nvn', 'tex') for p in (gfx / folder).iterdir()
                      if p.suffix in ('.c', '.m', '.S') and p.name != 'nvn_mtl.m')
    project = {
        'name': 'EDRVerification', 'options': {'deploymentTarget': {'iOS': '26.0'}},
        'targets': {'EDRVerification': {
            'type': 'application', 'platform': 'iOS',
            'sources': [{'path': str(p)} for p in sources],
            'dependencies': [{'sdk': name + '.framework'} for name in
                             ('UIKit', 'Metal', 'MetalFX', 'Foundation', 'QuartzCore',
                              'ImageIO', 'CoreGraphics', 'UniformTypeIdentifiers')],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.anygame.edr-verification',
                'ENABLE_DEBUG_DYLIB': 'NO', 'CODE_SIGN_STYLE': 'Automatic',
                'TARGETED_DEVICE_FAMILY': '1', 'CLANG_ENABLE_OBJC_ARC': 'YES',
                'GCC_OPTIMIZATION_LEVEL': '1',
                'HEADER_SEARCH_PATHS': [str(gfx / 'nvn/include'), str(include)],
            }},
            'info': {'path': 'Info.plist', 'properties': {
                'CFBundleDisplayName': 'EDR GPU Verification', 'UILaunchScreen': {},
                'UIFileSharingEnabled': True,
                'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
                    'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                        'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'EDRScene'}]}},
            }},
        }},
    }
    (output / 'project.yml').write_text(json.dumps(project, indent=2) + '\n')
    # Include production headers/shaders and the fixture's included test body in
    # the digest, not just directly compiled sources. The probe carries no payload.
    provenance = set(sources) | {REPO / 'dm/gfx/tests/t_edr_present.m'}
    provenance |= set((gfx / 'nvn').glob('*.h')) | set((gfx / 'nvn').glob('*.inc'))
    provenance |= set((gfx / 'nvn/include').glob('*.h')) | {gfx / 'nvn/nvn_mtl.m'}
    report = {'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
              'gameProfile': game, 'syntheticHeadroom': True, 'physicalHDRDisplayTested': False,
              'sha256': {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted(provenance)}}
    (output / 'source-provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(output / 'project.yml')], check=True)
    subprocess.run(['xcodebuild', '-project', str(output / 'EDRVerification.xcodeproj'),
                    '-scheme', 'EDRVerification', '-configuration', 'Debug',
                    '-destination', 'generic/platform=iOS', '-derivedDataPath', str(output / 'DerivedData'),
                    '-jobs', '3', 'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
    print(output / 'DerivedData/Build/Products/Debug-iphoneos/EDRVerification.app')


if __name__ == '__main__':
    main()
