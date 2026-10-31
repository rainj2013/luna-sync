#!/bin/bash
# Export an already-built archive. Credentials never enter the source/build cache.
set +x
set -euo pipefail
umask 077
fail() { echo "::error::$*" >&2; exit 1; }
[[ $# -eq 1 && -d "$1" ]] || fail 'Usage: export-ios-adhoc.sh <unsigned.xcarchive>'
archive=$1
script_dir=$(cd "$(dirname "$0")" && pwd)
# The family variant installs beside the developer build with a distinct label.
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 相存家庭版' "$archive/Products/Applications/LunaSync.app/Info.plist"
for name in RUNNER_TEMP APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_PROVISIONING_PROFILE APPLE_SIGNING_IDENTITY APPLE_TEAM_ID IOS_BUNDLE_ID; do
  [[ -n "${!name:-}" ]] || fail "Missing signing variable: $name"
done
work=$(mktemp -d "$RUNNER_TEMP/luna-ios-signing.XXXXXX")
keychain="$work/signing.keychain-db"
original_keychains=()
installed_profiles=()
while IFS= read -r item; do original_keychains+=("$item"); done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
cleanup() {
  security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  if [[ ${#installed_profiles[@]} -gt 0 ]]; then
    for profile in "${installed_profiles[@]}"; do rm -f "$profile"; done
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$work/certificate.p12"
printf '%s' "$APPLE_PROVISIONING_PROFILE" | base64 --decode > "$work/profile.mobileprovision"
password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain" >/dev/null
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
security find-identity -v -p codesigning "$keychain" | grep -F -- "\"$APPLE_SIGNING_IDENTITY\"" >/dev/null || fail 'Signing identity was not imported.'
security find-certificate -c "$APPLE_SIGNING_IDENTITY" -p "$keychain" > "$work/certificate.pem"
openssl x509 -in "$work/certificate.pem" -outform DER -out "$work/certificate.der"
security cms -D -i "$work/profile.mobileprovision" > "$work/profile.plist"
python3 "$script_dir/ios-adhoc-profile.py" "$work/profile.plist" "$work/certificate.der" "$APPLE_TEAM_ID" "$IOS_BUNDLE_ID" \
  --export-options "$work/ExportOptions.plist" > "$work/distribution-info.json"
uuid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["profileUUID"])' "$work/distribution-info.json")
for directory in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  mkdir -p "$directory"
  profile="$directory/$uuid.mobileprovision"
  if [[ -e "$profile" ]]; then
    cmp -s "$work/profile.mobileprovision" "$profile" || fail 'Existing profile differs; refusing to overwrite it.'
  else
    cp "$work/profile.mobileprovision" "$profile"
    installed_profiles+=("$profile")
  fi
done
rm "$work/certificate.p12"
unset APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_PROVISIONING_PROFILE password
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" -exportOptionsPlist "$work/ExportOptions.plist"
shopt -s nullglob
ipas=("$work/export/"*.ipa)
[[ ${#ipas[@]} -eq 1 ]] || fail 'Expected exactly one exported IPA.'
ditto -x -k "${ipas[0]}" "$work/verify"
apps=("$work/verify/Payload/"*.app)
[[ ${#apps[@]} -eq 1 ]] || fail 'Expected exactly one application.'
app=${apps[0]}
codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
grep -Fx -- "Authority=$APPLE_SIGNING_IDENTITY" <<< "$details" >/dev/null || fail 'Unexpected signer.'
cmp -s "$work/profile.mobileprovision" "$app/embedded.mobileprovision" || fail 'Exported app uses a different profile.'
python3 "$script_dir/verify-ios-adhoc.py" "$app" "$work/distribution-info.json"
mkdir -p release-assets
cp "${ipas[0]}" release-assets/LunaSync-family.ipa
cp "$work/distribution-info.json" release-assets/distribution-info.json
echo 'Ad Hoc IPA verified. Download it only from this private repository.'
