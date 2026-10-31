#!/usr/bin/env python3
"""Validate a decoded Ad Hoc profile without logging registered device IDs."""
import argparse
import datetime
import hashlib
import json
import plistlib
import re
from pathlib import Path


def validate(profile, certificate, team, bundle, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid team identifier")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle) or "*" in bundle:
        raise ValueError("An explicit bundle identifier is required")
    if profile.get("TeamIdentifier") != [team]:
        raise ValueError("Profile belongs to a different team")
    if "iOS" not in profile.get("Platform", []):
        raise ValueError("Expected an iOS provisioning profile")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        raise ValueError("Profile has no expiration date")
    expiry = expiry.replace(tzinfo=datetime.timezone.utc) if expiry.tzinfo is None else expiry
    if expiry <= now:
        raise ValueError("Profile has expired")
    devices = profile.get("ProvisionedDevices")
    if not isinstance(devices, list) or not devices or not all(isinstance(d, str) and d for d in devices):
        raise ValueError("Ad Hoc profile must contain registered devices")
    if profile.get("ProvisionsAllDevices", False):
        raise ValueError("Enterprise profiles are not allowed")
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("get-task-allow") is not False:
        raise ValueError("Development profiles are not allowed")
    if entitlements.get("application-identifier") != f"{team}.{bundle}":
        raise ValueError("Profile does not match the explicit app identifier")
    if entitlements.get("com.apple.developer.team-identifier") != team:
        raise ValueError("Profile entitlement team does not match")
    if certificate not in profile.get("DeveloperCertificates", []):
        raise ValueError("Signing certificate is not included in this profile")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", uuid):
        raise ValueError("Invalid profile UUID")
    return {"profileUUID": uuid, "profileName": profile.get("Name", ""),
            "expiresAt": expiry.isoformat(), "teamID": team, "bundleID": bundle,
            "deviceCount": len(devices), "certificateSHA1": hashlib.sha1(certificate).hexdigest().upper()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("certificate", type=Path)
    parser.add_argument("team")
    parser.add_argument("bundle")
    parser.add_argument("--export-options", type=Path)
    args = parser.parse_args()
    result = validate(plistlib.loads(args.profile.read_bytes()), args.certificate.read_bytes(), args.team, args.bundle)
    if args.export_options:
        args.export_options.write_bytes(plistlib.dumps({
            "method": "release-testing", "destination": "export", "signingStyle": "manual",
            "signingCertificate": result["certificateSHA1"], "teamID": args.team,
            "provisioningProfiles": {args.bundle: result["profileUUID"]},
            "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
            "thinning": "<none>"}))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"Invalid Ad Hoc profile: {error}") from None
