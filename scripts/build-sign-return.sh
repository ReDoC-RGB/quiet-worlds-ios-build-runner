#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

required=(QW_APPLE_P12_B64 QW_APPLE_P12_PASSWORD QW_APPLE_PROFILE_B64 QW_EXPORT_SHA256 QW_EXPORT_TOKEN QW_EXPORT_URL QW_MANIFEST_URL)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { printf 'required protected input is missing\n' >&2; exit 2; }
done

ROOT="${RUNNER_TEMP}/qw-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
RESULT_DIR="${RUNNER_TEMP}/qw-result-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
KEYCHAIN="${ROOT}/quiet-worlds.keychain-db"
EXPORT_ARCHIVE="${ROOT}/quiet-worlds-xcode-export.tar.gz"
EXPORT_MANIFEST="${ROOT}/quiet-worlds-xcode-export-manifest.json"
readonly EXPECTED_TEAM_ID="7D88UFWRTZ"
readonly EXPECTED_PROFILE_UUID="3b5d5cd7-a4d3-43ff-b3e1-c0c3a81ffdc8"
readonly EXPECTED_PROFILE_SHA="fa3a0823eabfc9b6fd93325e7f5cd947b231325430823a603b75963468bab742"
readonly EXPECTED_CERT_SHA="3870fd7a823c074b79fdf2862c3a57b5432bcce43b963e759f81ea3789e1a107"
mkdir -p "${ROOT}"
cleanup() { "${GITHUB_WORKSPACE}/scripts/cleanup.sh"; }
trap cleanup EXIT

curl --fail --silent --show-error --location --proto '=https' \
  --header "Authorization: Bearer ${QW_EXPORT_TOKEN}" \
  --output "${EXPORT_ARCHIVE}" "${QW_EXPORT_URL}"
curl --fail --silent --show-error --location --proto '=https' \
  --header "Authorization: Bearer ${QW_EXPORT_TOKEN}" \
  --output "${EXPORT_MANIFEST}" "${QW_MANIFEST_URL}"
[[ "$(shasum -a 256 "${EXPORT_ARCHIVE}" | cut -d ' ' -f 1)" == "${QW_EXPORT_SHA256}" ]] || { printf 'archive authority mismatch\n' >&2; exit 2; }
[[ "$(shasum -a 256 "${EXPORT_MANIFEST}" | cut -d ' ' -f 1)" == "fb9e2b95f5b5cef5eeef4852242d0261099597f1bb31a5ed10e2e2993a3f484e" ]] || { printf 'manifest authority mismatch\n' >&2; exit 2; }
python3 - "${EXPORT_MANIFEST}" <<'PY'
import json,sys
b=open(sys.argv[1],'rb').read();assert not b.startswith(b'\x1f\x8b');x=json.loads(b.decode('utf-8'));assert len(x['fileInventory'])==2994 and x['framedTreeSha256']=='82e6bd71b0dfbcdb80f61e342a41622e2212194e59c5877df84dec25ab420472'
PY
python3 "${GITHUB_WORKSPACE}/scripts/verify-public-runner.py" verify-export \
  --archive "${EXPORT_ARCHIVE}" --manifest "${EXPORT_MANIFEST}" --expected-sha "${QW_EXPORT_SHA256}"
mkdir -p "${ROOT}/payload"
tar -xzf "${EXPORT_ARCHIVE}" -C "${ROOT}/payload" --no-same-owner --no-same-permissions
XCODE_ROOT="${ROOT}/payload/xcode-export"
[[ -d "${XCODE_ROOT}" ]] || { printf 'verified Xcode export root missing\n' >&2; exit 3; }

P12="${ROOT}/distribution.p12"
PROFILE="${ROOT}/quiet-worlds.mobileprovision"
python3 - "${P12}" "${PROFILE}" <<'PY'
import base64,os,sys
open(sys.argv[1],'wb').write(base64.b64decode(os.environ['QW_APPLE_P12_B64'],validate=True))
open(sys.argv[2],'wb').write(base64.b64decode(os.environ['QW_APPLE_PROFILE_B64'],validate=True))
PY
unset QW_APPLE_P12_B64 QW_APPLE_PROFILE_B64
chmod 0600 "${P12}" "${PROFILE}"

KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security set-keychain-settings -lut 21600 "${KEYCHAIN}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security import "${P12}" -k "${KEYCHAIN}" -P "${QW_APPLE_P12_PASSWORD}" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}" >/dev/null
security list-keychains -d user -s "${KEYCHAIN}"

PROFILE_PLIST="${ROOT}/profile.plist"
security cms -D -i "${PROFILE}" > "${PROFILE_PLIST}"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "${PROFILE_PLIST}")"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${PROFILE_PLIST}")"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${PROFILE_PLIST}")"
APPLICATION_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${PROFILE_PLIST}")"
PROFILE_FILE_SHA="$(shasum -a 256 "${PROFILE}" | cut -d ' ' -f 1)"
[[ "${PROFILE_FILE_SHA}" == "${EXPECTED_PROFILE_SHA}" && "${PROFILE_UUID}" == "${EXPECTED_PROFILE_UUID}" && "${TEAM_ID}" == "${EXPECTED_TEAM_ID}" && "${APPLICATION_IDENTIFIER}" == "${EXPECTED_TEAM_ID}.com.wellmadesystems.quietworlds" ]] || { printf 'profile authority mismatch\n' >&2; exit 4; }
PROFILE_DEST="${HOME}/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.mobileprovision"
mkdir -p "$(dirname "${PROFILE_DEST}")"
install -m 0600 "${PROFILE}" "${PROFILE_DEST}"
printf '%s\n' "${PROFILE_DEST}" > "${ROOT}/installed-profile-path.txt"

P12_CERT_PEM="${ROOT}/distribution-cert.pem"
P12_CERT_DER="${ROOT}/distribution-cert.der"
openssl pkcs12 -in "${P12}" -clcerts -nokeys -passin "pass:${QW_APPLE_P12_PASSWORD}" -out "${P12_CERT_PEM}" >/dev/null 2>&1
openssl x509 -in "${P12_CERT_PEM}" -outform DER -out "${P12_CERT_DER}"
P12_CERT_SHA1="$(shasum -a 1 "${P12_CERT_DER}" | cut -d ' ' -f 1 | tr '[:lower:]' '[:upper:]')"
QW_EXPECTED_CERT_SHA="$(shasum -a 256 "${P12_CERT_DER}" | cut -d ' ' -f 1)"
[[ "${QW_EXPECTED_CERT_SHA}" == "${EXPECTED_CERT_SHA}" ]] || { printf 'distribution certificate authority mismatch\n' >&2; exit 5; }
if ! IDENTITY_OUTPUT="$(security find-identity -v -p codesigning "${KEYCHAIN}")"; then
  printf 'unable to enumerate usable distribution identities\n' >&2
  exit 5
fi
if ! IDENTITY_COUNT="$(printf '%s\n' "${IDENTITY_OUTPUT}" | "${GITHUB_WORKSPACE}/scripts/count-signing-identities.sh" "${P12_CERT_SHA1}")"; then
  printf 'invalid distribution identity lookup output\n' >&2
  exit 5
fi
[[ "${IDENTITY_COUNT}" == 1 ]] || { printf 'usable distribution identity mismatch: expected 1, found %s\n' "${IDENTITY_COUNT}" >&2; exit 5; }
unset IDENTITY_OUTPUT
unset QW_APPLE_P12_PASSWORD KEYCHAIN_PASSWORD
export QW_EXPECTED_CERT_SHA
export QW_EXPECTED_TEAM_ID="${TEAM_ID}"
export QW_EXPECTED_PROFILE_UUID="${PROFILE_UUID}"

WORKSPACE_COUNT="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcworkspace' -print | wc -l | tr -d ' ')"
PROJECT_COUNT="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcodeproj' -print | wc -l | tr -d ' ')"
XCODE_CONTAINER_ARGS=()
if [[ "${WORKSPACE_COUNT}" == 1 ]]; then
  WORKSPACE="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcworkspace' -print -quit)"
  XCODE_CONTAINER_ARGS=(-workspace "${WORKSPACE}")
elif [[ "${WORKSPACE_COUNT}" == 0 && "${PROJECT_COUNT}" == 1 ]]; then
  PROJECT="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcodeproj' -print -quit)"
  XCODE_CONTAINER_ARGS=(-project "${PROJECT}")
else
  printf 'expected exactly one Xcode workspace or one Xcode project\n' >&2
  exit 5
fi
ARCHIVE_PATH="${ROOT}/QuietWorlds.xcarchive"
XCODE_LOG="${ROOT}/xcodebuild.log"
# The protected log prevents signing values from entering public output. xcodebuild archive
if ! xcodebuild "${XCODE_CONTAINER_ARGS[@]}" -scheme Unity-iPhone -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" PRODUCT_BUNDLE_IDENTIFIER=com.wellmadesystems.quietworlds \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${P12_CERT_SHA1}" \
  OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN}" PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME}" archive >"${XCODE_LOG}" 2>&1; then
  printf 'Xcode archive failed; protected build log retained only for always-run deletion\n' >&2
  exit 6
fi

EXPORT_OPTIONS="${ROOT}/ExportOptions.plist"
export QW_PROFILE_NAME="${PROFILE_NAME}"
python3 - "${EXPORT_OPTIONS}" <<'PY'
import os,plistlib,sys
value={
  'method':'ad-hoc','destination':'export','signingStyle':'manual','teamID':os.environ['QW_EXPECTED_TEAM_ID'],
  'stripSwiftSymbols':True,'compileBitcode':False,
  'provisioningProfiles':{'com.wellmadesystems.quietworlds':os.environ['QW_PROFILE_NAME']},
}
with open(sys.argv[1],'wb') as stream: plistlib.dump(value,stream,sort_keys=True)
PY
unset QW_PROFILE_NAME

IPA_DIR="${ROOT}/ipa-output"
mkdir -p "${IPA_DIR}"
if ! xcodebuild -exportArchive -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${IPA_DIR}" -exportOptionsPlist "${EXPORT_OPTIONS}" >>"${XCODE_LOG}" 2>&1; then
  printf 'Xcode Ad Hoc export failed; protected build log retained only for always-run deletion\n' >&2
  exit 7
fi
IPA_COUNT="$(find "${IPA_DIR}" -maxdepth 1 -type f -name '*.ipa' -print | wc -l | tr -d ' ')"
[[ "${IPA_COUNT}" == 1 ]] || { printf 'expected one signed IPA\n' >&2; exit 8; }
IPA="$(find "${IPA_DIR}" -maxdepth 1 -type f -name '*.ipa' -print -quit)"

VERIFY_ROOT="${ROOT}/verify-ipa"
mkdir -p "${VERIFY_ROOT}"
python3 "${GITHUB_WORKSPACE}/scripts/verify-public-runner.py" verify-ipa-archive --ipa "${IPA}"
ditto -x -k "${IPA}" "${VERIFY_ROOT}"
APP_COUNT="$(find "${VERIFY_ROOT}/Payload" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')"
[[ "${APP_COUNT}" == 1 ]] || { printf 'expected one signed app in IPA\n' >&2; exit 9; }
APP="$(find "${VERIFY_ROOT}/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
codesign --verify --deep --strict --verbose=2 "${APP}" >"${ROOT}/codesign-verify.log" 2>&1
APP_CERT_PREFIX="${ROOT}/app-signing-cert"
codesign --display --extract-certificates "${APP_CERT_PREFIX}" "${APP}" >"${ROOT}/codesign-display.log" 2>&1
[[ -f "${APP_CERT_PREFIX}0" ]] || { printf 'app signing certificate extraction failed\n' >&2; exit 10; }
QW_APP_SIGNING_CERT_SHA="$(shasum -a 256 "${APP_CERT_PREFIX}0" | cut -d ' ' -f 1)"
[[ "${QW_APP_SIGNING_CERT_SHA}" == "${QW_EXPECTED_CERT_SHA}" ]] || { printf 'app signing certificate continuity mismatch\n' >&2; exit 11; }
export QW_APP_SIGNING_CERT_SHA
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP}/Info.plist")"
lipo -archs "${APP}/${EXECUTABLE}" | tr ' ' '\n' | grep -Fx arm64 >/dev/null
VERIFICATION="${ROOT}/quiet-worlds-ios-verification.json"
python3 "${GITHUB_WORKSPACE}/scripts/verify-public-runner.py" verify-ipa \
  --ipa "${IPA}" --manifest "${EXPORT_MANIFEST}" --output "${VERIFICATION}"
unset QW_APP_SIGNING_CERT_SHA QW_EXPECTED_CERT_SHA QW_EXPECTED_TEAM_ID QW_EXPECTED_PROFILE_UUID PROFILE_UUID PROFILE_NAME TEAM_ID APPLICATION_IDENTIFIER
mkdir -p "${RESULT_DIR}"
install -m 0600 "${IPA}" "${RESULT_DIR}/quiet-worlds.ipa"
install -m 0600 "${VERIFICATION}" "${RESULT_DIR}/quiet-worlds-ios-verification.json"
unset QW_EXPORT_SHA256 QW_EXPORT_TOKEN QW_EXPORT_URL QW_MANIFEST_URL
printf 'PASS one signed Ad Hoc IPA was verified and staged for one private artifact upload\n'
