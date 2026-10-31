#!/usr/bin/env python3
"""Verify exported bundle metadata and signed entitlements without printing UDIDs."""
import json
import plistlib
from pathlib import Path
import subprocess
import sys

app, report = map(Path, sys.argv[1:])
expected = json.loads(report.read_text())
info = plistlib.loads((app / "Info.plist").read_bytes())
if info.get("CFBundleIdentifier") != expected["bundleID"]:
    raise SystemExit("Exported app bundle ID does not match")
if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
    raise SystemExit("Expected a device build, not a simulator build")
if info.get("CFBundleDisplayName") != "相存":
    raise SystemExit("Expected the app display name 相存")
result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], capture_output=True, check=True)
entitlements = plistlib.loads(result.stdout)
if entitlements.get("get-task-allow") is not False:
    raise SystemExit("Exported app has development entitlements")
if entitlements.get("application-identifier") != expected["teamID"] + "." + expected["bundleID"]:
    raise SystemExit("Exported app has an unexpected signed application identifier")
if entitlements.get("com.apple.developer.team-identifier") != expected["teamID"]:
    raise SystemExit("Exported app has an unexpected team")
expected.update(version=info["CFBundleShortVersionString"], build=info["CFBundleVersion"], displayName=info["CFBundleDisplayName"])
report.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n")
print("Exported device app metadata and distribution entitlements verified")
