"""Check the actual IPA-builder scene opt-in against a generated-style plist."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


class ExternalSceneConfigurationTests(unittest.TestCase):
    def configure(self, enabled):
        script = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        block = script.split('# Explicit build opt-in:', 1)[1].split('# DM_METAL_CAPTURE=1:', 1)[0]
        block = block[block.index('\n') + 1:]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Gen').mkdir()
            path = root / 'Gen/Info.plist'
            original = plistlib.dumps({'UIApplicationSceneManifest': {
                'UIApplicationSupportsMultipleScenes': False,
                'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                    'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'SceneDelegate'}]}}})
            path.write_bytes(original)
            environment = {'PATH': os.defpath}
            if enabled is not None:
                environment['DM_EXTERNAL_DISPLAY'] = enabled
            result = subprocess.run(['bash', '-c', 'die() { exit 1; };\n' + block],
                                    cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return original, path.read_bytes()

    def test_default_and_explicit_zero_preserve_scene_manifest(self):
        for value in (None, '0'):
            with self.subTest(value=value):
                original, configured = self.configure(value)
                self.assertEqual(configured, original)

    def test_opt_in_advertises_only_the_noninteractive_external_role(self):
        _, configured = self.configure('1')
        info = plistlib.loads(configured)
        self.assertTrue(info['DMExternalDisplayEnabled'])
        manifest = info['UIApplicationSceneManifest']
        self.assertFalse(manifest['UIApplicationSupportsMultipleScenes'])
        configurations = manifest['UISceneConfigurations']
        self.assertEqual(set(configurations), {'UIWindowSceneSessionRoleApplication',
                                              'UIWindowSceneSessionRoleExternalDisplayNonInteractive'})
        self.assertEqual(configurations['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName'], 'SceneDelegate')
        self.assertEqual(configurations['UIWindowSceneSessionRoleExternalDisplayNonInteractive'], [{
            'UISceneConfigurationName': 'External game display', 'UISceneDelegateClassName': 'DmExternalSceneDelegate'}])


if __name__ == '__main__':
    unittest.main()
