#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/build-sign-return.sh"
python3 - "$script" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'^xcodebuild .*?\barchive >"\$\{XCODE_LOG\}" 2>&1$', text, re.MULTILINE | re.DOTALL)
if not match:
    raise SystemExit('FAIL expected one xcodebuild archive command')
command = match.group(0)
settings = re.findall(r'\bPROVISIONING_PROFILE_SPECIFIER(?:_[A-Za-z0-9_]+)?=', command)
expected = ['PROVISIONING_PROFILE_SPECIFIER_APP=']
if settings != expected:
    raise SystemExit(f'FAIL archive profile settings were {settings!r}; expected {expected!r}')
if re.search(r'\bPROVISIONING_PROFILE_SPECIFIER=', command):
    raise SystemExit('FAIL unsuffixed provisioning profile setting leaks to every target')
if re.search(r'PROVISIONING_PROFILE_SPECIFIER[^=]*(?:FRAMEWORK|UnityFramework)', command, re.IGNORECASE):
    raise SystemExit('FAIL framework provisioning profile setting is forbidden')
if command.count('PROVISIONING_PROFILE_SPECIFIER_APP="${PROFILE_NAME}"') != 1:
    raise SystemExit('FAIL expected exactly one app-suffixed profile value')
print('PASS archive applies exactly one app-suffixed profile and no unsuffixed/framework profile setting')
PY
