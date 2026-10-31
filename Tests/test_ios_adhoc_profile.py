import copy
import datetime
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("adhoc", Path(__file__).resolve().parents[1] / "scripts/ios-adhoc-profile.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AdHocValidationTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
        self.certificate = b"test certificate bytes"
        self.profile = {
            "TeamIdentifier": ["TESTTEAM01"], "Platform": ["iOS"],
            "ExpirationDate": datetime.datetime(2027, 1, 1),
            "UUID": "12345678-1234-1234-1234-123456789abc", "Name": "Family test",
            "ProvisionedDevices": ["PRIVATE_DEVICE_SENTINEL"],
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {"application-identifier": "TESTTEAM01.dev.test.family",
                             "com.apple.developer.team-identifier": "TESTTEAM01", "get-task-allow": False}}

    def check_profile(self, **changes):
        profile = copy.deepcopy(self.profile)
        profile.update(changes)
        return module.validate(profile, self.certificate, "TESTTEAM01", "dev.test.family", self.now)

    def test_accepts_matching_distribution_profile_without_logging_device_ids(self):
        result = self.check_profile()
        self.assertEqual(result["deviceCount"], 1)
        self.assertNotIn("PRIVATE_DEVICE_SENTINEL", json.dumps(result))

    def test_rejects_expired_profile(self):
        with self.assertRaisesRegex(ValueError, "expired"):
            self.check_profile(ExpirationDate=self.now - datetime.timedelta(seconds=1))

    def test_rejects_app_store_profile_without_registered_devices(self):
        with self.assertRaisesRegex(ValueError, "registered devices"):
            self.check_profile(ProvisionedDevices=[])

    def test_rejects_enterprise_profile(self):
        with self.assertRaisesRegex(ValueError, "Enterprise"):
            self.check_profile(ProvisionsAllDevices=True)

    def test_rejects_development_profile(self):
        entitlements = dict(self.profile["Entitlements"], **{"get-task-allow": True})
        with self.assertRaisesRegex(ValueError, "Development"):
            self.check_profile(Entitlements=entitlements)

    def test_rejects_wrong_app_or_wildcard(self):
        for identifier in ["TESTTEAM01.other.app", "TESTTEAM01.*"]:
            with self.subTest(identifier=identifier), self.assertRaisesRegex(ValueError, "explicit app"):
                self.check_profile(Entitlements=dict(self.profile["Entitlements"], **{"application-identifier": identifier}))

    def test_rejects_wrong_team(self):
        with self.assertRaisesRegex(ValueError, "different team"):
            self.check_profile(TeamIdentifier=["OTHERTEAM1"])

    def test_rejects_wrong_certificate(self):
        with self.assertRaisesRegex(ValueError, "certificate"):
            self.check_profile(DeveloperCertificates=[b"different certificate"])

    def test_rejects_non_ios_profile(self):
        with self.assertRaisesRegex(ValueError, "iOS"):
            self.check_profile(Platform=["OSX"])


if __name__ == "__main__":
    unittest.main()
