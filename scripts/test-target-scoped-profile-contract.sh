#!/usr/bin/env bash
set -euo pipefail
scripts="$(cd "$(dirname "$0")" && pwd)"
script="${scripts}/build-sign-return.sh"
verifier="${scripts}/verify-public-runner.py"
: "${QW_XCODE_PROJECT_PBXPROJ:?set QW_XCODE_PROJECT_PBXPROJ to the already-exported Unity project.pbxproj}"
python3 - "$script" "$verifier" "$QW_XCODE_PROJECT_PBXPROJ" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
verifier = pathlib.Path(sys.argv[2]).read_text()
project = pathlib.Path(sys.argv[3]).read_text()
match = re.search(r'^xcodebuild .*?\barchive >"\$\{XCODE_LOG\}" 2>&1$', text, re.MULTILINE | re.DOTALL)
if not match:
    raise SystemExit('FAIL expected one xcodebuild archive command')
command = match.group(0)

bundle_settings = re.findall(r'\bPRODUCT_BUNDLE_IDENTIFIER(?:_[A-Za-z0-9_]+)?=', command)
if bundle_settings:
    raise SystemExit(f'FAIL archive bundle identifier settings were {bundle_settings!r}; expected none')
profile_settings = re.findall(r'\bPROVISIONING_PROFILE_SPECIFIER(?:_[A-Za-z0-9_]+)?=', command)
expected_profiles = ['PROVISIONING_PROFILE_SPECIFIER_APP=']
if profile_settings != expected_profiles:
    raise SystemExit(f'FAIL archive profile settings were {profile_settings!r}; expected {expected_profiles!r}')
if re.search(r'\bPROVISIONING_PROFILE_SPECIFIER=', command):
    raise SystemExit('FAIL unsuffixed provisioning profile setting leaks to every target')
if re.search(r'PROVISIONING_PROFILE_SPECIFIER[^=]*(?:FRAMEWORK|UnityFramework)', command, re.IGNORECASE):
    raise SystemExit('FAIL framework provisioning profile setting is forbidden')
if command.count('PROVISIONING_PROFILE_SPECIFIER_APP="${PROFILE_NAME}"') != 1:
    raise SystemExit('FAIL expected exactly one app-suffixed profile value')
if 'BUNDLE = "com.wellmadesystems.quietworlds"' not in verifier:
    raise SystemExit('FAIL verifier application identity authority is missing')
if "'provisioningProfiles':{'com.wellmadesystems.quietworlds':os.environ['QW_PROFILE_NAME']}" not in text:
    raise SystemExit('FAIL export options do not map the profile only to the application bundle identifier')
if re.search(r"provisioningProfiles.*(?:UnityFramework|com\.unity3d\.framework)", text):
    raise SystemExit('FAIL export options assign a provisioning profile to UnityFramework')

native = project.split('/* Begin PBXNativeTarget section */', 1)[1].split('/* End PBXNativeTarget section */', 1)[0]

def target_body(name: str) -> str:
    found = re.search(r'\n\s*[A-F0-9]+ /\* ' + re.escape(name) + r' \*/ = \{(.*?)\n\s*\};', native, re.S)
    if not found:
        raise SystemExit(f'FAIL missing {name} target')
    return found.group(1)

app = target_body('Unity-iPhone')
framework = target_body('UnityFramework')
if 'productType = "com.apple.product-type.application";' not in app:
    raise SystemExit('FAIL Unity-iPhone is not an application target')
if 'productType = "com.apple.product-type.framework";' not in framework:
    raise SystemExit('FAIL UnityFramework is not a framework target')
if project.count('PRODUCT_BUNDLE_IDENTIFIER = com.wellmadesystems.quietworlds;') != 4:
    raise SystemExit('FAIL Unity-iPhone does not resolve to the expected bundle identifier in all configurations')
if project.count('PRODUCT_BUNDLE_IDENTIFIER = com.unity3d.framework;') != 4:
    raise SystemExit('FAIL UnityFramework does not retain its framework bundle identifier in all configurations')
if project.count('PROVISIONING_PROFILE_SPECIFIER = "$(PROVISIONING_PROFILE_SPECIFIER_APP)";') != 4:
    raise SystemExit('FAIL application target does not retain the app-scoped profile indirection')
if project.count('PROVISIONING_PROFILE_SPECIFIER = "";') < 4:
    raise SystemExit('FAIL framework target provisioning profile is not empty')
print('PASS zero archive bundle overrides, one app-scoped profile, and verified application/framework target settings')
PY
