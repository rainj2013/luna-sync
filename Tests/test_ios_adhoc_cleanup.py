import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Needs macOS signing tools")
class ExportCleanupTests(unittest.TestCase):
    def test_failed_certificate_import_removes_temporary_credentials(self):
        with tempfile.TemporaryDirectory(prefix="luna-adhoc-cleanup-") as directory:
            root = Path(directory)
            runtime = root / "runtime"
            runtime.mkdir()
            archive = root / "test.xcarchive"
            archive.mkdir()
            import plistlib
            app = archive / "Products/Applications/LunaSync.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleDisplayName": "相存"}))
            binary = root / "security"
            binary.write_text('''#!/bin/bash
case "$1" in
  list-keychains) [[ "$*" == *' -s '* ]] || echo '    "/tmp/original.keychain-db"' ;;
  import) exit 9 ;;
  delete-keychain) echo deleted >> "$MOCK_EVENTS" ;;
esac
exit 0
''')
            binary.chmod(0o755)
            sentinel = "PRIVATE_CERTIFICATE_TEST_SENTINEL"
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       RUNNER_TEMP=str(runtime), MOCK_EVENTS=str(root / "events"),
                       APPLE_CERTIFICATE=base64.b64encode(sentinel.encode()).decode(),
                       APPLE_CERTIFICATE_PASSWORD="TEST_PASSWORD_SENTINEL",
                       APPLE_PROVISIONING_PROFILE=base64.b64encode(b"PROFILE_SENTINEL").decode(),
                       APPLE_SIGNING_IDENTITY="Apple Distribution: Test (TESTTEAM01)",
                       APPLE_TEAM_ID="TESTTEAM01", IOS_BUNDLE_ID="dev.test.family")
            script = Path(__file__).resolve().parents[1] / "scripts/export-ios-adhoc.sh"
            result = subprocess.run(["/bin/bash", str(script), str(archive)], env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(runtime.iterdir()), [])
            self.assertIn("deleted", (root / "events").read_text())
            for secret in [sentinel, env["APPLE_CERTIFICATE"], env["APPLE_CERTIFICATE_PASSWORD"], "PROFILE_SENTINEL"]:
                self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
