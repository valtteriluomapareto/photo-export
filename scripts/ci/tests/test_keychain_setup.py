"""Execute keychain setup only with offline commands and explicit fake inputs."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
PASSWORD = '00000000-1111-2222-3333-444444444444'
EXISTING = ['/Users/offline/Library/Keychains/login with spaces.keychain-db',
            '/Library/Keychains/System.keychain']


class KeychainSetupTests(unittest.TestCase):
    def run_setup(self, channel):
        with tempfile.TemporaryDirectory(prefix='keychain fixture ') as temporary:
            root = Path(temporary)
            runner = root / 'runner space'
            runner.mkdir()
            binaries = root / 'bin'
            binaries.mkdir()
            for name, target in {'base64': '/usr/bin/base64', 'tr': '/usr/bin/tr',
                                 'awk': '/usr/bin/awk', 'rm': '/bin/rm'}.items():
                (binaries / name).symlink_to(target)
            stub = f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
allowed = {"create-keychain", "set-keychain-settings", "unlock-keychain", "list-keychains",
           "default-keychain", "import", "set-key-partition-list", "find-identity", "find-certificate"}
valid = (name == "uuidgen" and not args or name == "security" and args and args[0] in allowed
         or name == "xcrun" and args[:2] == ["notarytool", "store-credentials"])
if not valid:
    pathlib.Path(os.environ["UNEXPECTED"]).write_text(repr([name, *args]))
    sys.exit(97)
with open(os.environ["CALLS"], "a") as stream:
    stream.write(json.dumps([name, *args]) + "\\n")
if name == "uuidgen":
    print(os.environ["FAKE_PASSWORD"])
elif os.environ["FAKE_PASSWORD"] in args:
    print("PASSWORD_USE")
    exported = pathlib.Path(os.environ["GITHUB_ENV"])
    if exported.exists() and "KEYCHAIN_PASSWORD=" in exported.read_text(): print("EXPORTED_EARLY")
elif name == "security" and args == ["list-keychains", "-d", "user"]:
    for path in json.loads(os.environ["EXISTING"]): print('    "' + path + '"')
elif name == "security" and args[0] == "find-identity":
    print('  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Mac Installer Distribution: Offline"')
'''
            for name in ['uuidgen', 'security', 'xcrun']:
                executable = binaries / name
                executable.write_text(stub)
                executable.chmod(0o755)
            environment = dict(PATH=str(binaries), RUNNER_TEMP=str(runner),
                               GITHUB_ENV=str(root / 'environment'), CALLS=str(root / 'calls'),
                               FAKE_PASSWORD=PASSWORD, EXISTING=json.dumps(EXISTING),
                               UNEXPECTED=str(root / 'unexpected'))
            environment.update({name: 'b2ZmbGluZQ==' for name in [
                'CERTIFICATE_P12_BASE64', 'CERTIFICATE_PASSWORD', 'APPLE_ID',
                'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID',
                'APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64',
                'APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD',
                'MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_P12_BASE64',
                'MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_PASSWORD']})
            script = ROOT / f'scripts/ci/setup-keychain-{channel}.sh'
            result = subprocess.run(['/bin/bash', str(script)], cwd=root, env=environment,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((root / 'unexpected').exists(), 'A non-fixture command was attempted')
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            exported = dict(line.split('=', 1) for line in (root / 'environment').read_text().splitlines())
            search = [call for call in calls if call[:5] == ['security', 'list-keychains', '-d', 'user', '-s']]
            self.assertEqual(search, [['security', 'list-keychains', '-d', 'user', '-s',
                                       exported['KEYCHAIN_PATH'], *EXISTING]])
            self.assertTrue(exported['KEYCHAIN_PATH'].startswith(str(runner) + '/'))
            lines = result.stdout.splitlines()
            mask = f'::add-mask::{PASSWORD}'
            self.assertLess(lines.index(mask), lines.index('PASSWORD_USE'))
            self.assertNotIn('EXPORTED_EARLY', lines)
            self.assertEqual([line for line in lines if PASSWORD in line], [mask])
            self.assertNotIn(PASSWORD, result.stderr)
            self.assertEqual(exported['KEYCHAIN_PASSWORD'], PASSWORD)

    def test_appstore_preserves_complete_search_paths_and_masks_password(self):
        self.run_setup('appstore')
