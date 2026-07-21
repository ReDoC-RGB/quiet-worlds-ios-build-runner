#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "${FIXTURE}"' EXIT
export RUNNER_TEMP="${FIXTURE}/runner-temp"
export HOME="${FIXTURE}/home"
export GITHUB_WORKSPACE="${FIXTURE}/workspace"
export GITHUB_RUN_ID=6006
export GITHUB_RUN_ATTEMPT=1
export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "${RUNNER_TEMP}" "${HOME}" "${GITHUB_WORKSPACE}"

# RED: the pre-correction shape kept the only Xcode log inside ROOT, so cleanup lost it.
OLD_ROOT="${RUNNER_TEMP}/old-root"
mkdir -p "${OLD_ROOT}"
printf 'error: RED fixture compiler failure\n' > "${OLD_ROOT}/xcodebuild.log"
rm -rf -- "${OLD_ROOT}"
[[ ! -e "${OLD_ROOT}/xcodebuild.log" ]]

ROOT="${RUNNER_TEMP}/qw-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
DIAGNOSTIC_DIR="${RUNNER_TEMP}/qw-diagnostic-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
PROTECTED_VALUES="${ROOT}/protected-values.nul"
RAW_LOG="${ROOT}/xcodebuild.log"
PROFILE_DEST="${HOME}/Library/MobileDevice/Provisioning Profiles/fixture.mobileprovision"
mkdir -p "${ROOT}/payload" "$(dirname "${PROFILE_DEST}")"
printf 'p12-bytes\n' > "${ROOT}/distribution.p12"
printf 'profile-bytes\n' > "${ROOT}/quiet-worlds.mobileprovision"
printf 'keychain-bytes\n' > "${ROOT}/quiet-worlds.keychain-db"
printf 'installed-profile\n' > "${PROFILE_DEST}"
printf '%s\n' "${PROFILE_DEST}" > "${ROOT}/installed-profile-path.txt"
printf 'payload\n' > "${ROOT}/payload/private-game-payload"

FIXTURE_TOKEN='fixture-token-must-not-survive'
FIXTURE_URL='https://private.invalid/opaque/input'
FIXTURE_PASSWORD='fixture-p12-password-must-not-survive'
FIXTURE_P12_B64='RklYVFVSRV9QMTJfQ1JFREVOVElBTA=='
FIXTURE_PROFILE_B64='RklYVFVSRV9QUk9GSUxFX0NSRURFTlRJQUw='
python3 - "${PROTECTED_VALUES}" "${FIXTURE_TOKEN}" "${FIXTURE_URL}" "${FIXTURE_PASSWORD}" "${FIXTURE_P12_B64}" "${FIXTURE_PROFILE_B64}" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(b"\0".join(value.encode() for value in sys.argv[2:]) + b"\0")
PY

cat > "${RAW_LOG}" <<EOF
CompileC ${GITHUB_WORKSPACE}/build/Object.o ${GITHUB_WORKSPACE}/Source/File.mm normal arm64
${GITHUB_WORKSPACE}/Source/File.mm:42:7: error: use of undeclared identifier 'QWFixtureCompilerFailure'
Ld ${RUNNER_TEMP}/qw-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}/QuietWorlds normal arm64
Undefined symbols for architecture arm64:
  "_QWFixtureLinkerFailure", referenced from:
error: The project 'Unity-iPhone' does not contain a scheme named 'FixtureScheme'.
error: Provisioning profile "Fixture Ad Hoc" doesn't include the com.apple.developer.associated-domains entitlement.
CodeSign ${HOME}/Library/Developer/Xcode/DerivedData/QuietWorlds.app
error: Signing certificate "Apple Distribution" is not trusted.
Authorization: Bearer ${FIXTURE_TOKEN}
private URL ${FIXTURE_URL}
password ${FIXTURE_PASSWORD}
p12 ${FIXTURE_P12_B64}
profile ${FIXTURE_PROFILE_B64}
EOF

python3 "${REPO_ROOT}/scripts/stage-xcode-diagnostic.py" \
  --raw-log "${RAW_LOG}" \
  --output-dir "${DIAGNOSTIC_DIR}" \
  --exit-status 65 \
  --phase archive \
  --protected-values-file "${PROTECTED_VALUES}"

[[ "$(cat "${DIAGNOSTIC_DIR}/xcodebuild-exit-status.txt")" == 65 ]]
grep -F "error: use of undeclared identifier 'QWFixtureCompilerFailure'" "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'Undefined symbols for architecture arm64:' "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F "error: The project 'Unity-iPhone' does not contain a scheme named 'FixtureScheme'." "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'Provisioning profile "Fixture Ad Hoc"' "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'com.apple.developer.associated-domains entitlement' "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'error: Signing certificate "Apple Distribution" is not trusted.' "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '<GITHUB_WORKSPACE>' "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '<RUNNER_TEMP>' "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '<HOME>' "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"

python3 - "${DIAGNOSTIC_DIR}" "${PROTECTED_VALUES}" "${RUNNER_TEMP}" "${HOME}" "${GITHUB_WORKSPACE}" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
protected = [value for value in Path(sys.argv[2]).read_bytes().split(b"\0") if value]
staged = b"\n".join(path.read_bytes() for path in sorted(out.iterdir()))
for value in protected + [value.encode() for value in sys.argv[3:]]:
    assert value not in staged
summary = json.loads((out / "summary.json").read_text())
assert summary["phase"] == "archive"
assert summary["xcodebuildExitStatus"] == 65
assert summary["sanitizationProof"] == "PASS"
assert summary["sanitizedLogByteLength"] > 0
PY

bash "${REPO_ROOT}/scripts/cleanup.sh"
[[ ! -e "${ROOT}" ]]
[[ ! -e "${PROFILE_DEST}" ]]
[[ -s "${DIAGNOSTIC_DIR}/xcodebuild-sanitized.log" ]]
[[ -s "${DIAGNOSTIC_DIR}/summary.json" ]]
printf 'PASS RED log-loss fixture and GREEN diagnostic sanitization/survival/cleanup fixtures\n'
