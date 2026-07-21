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
ARCHIVE_DIAGNOSTIC_DIR="${RUNNER_TEMP}/qw-diagnostic-archive-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
EXPORT_DIAGNOSTIC_DIR="${RUNNER_TEMP}/qw-diagnostic-export-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
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
FIXTURE_PRIVATE_LINUX_PATH='/home/private-builder/private-unity-export/Library/BuildCache/objects/fixture.o'
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
private Linux build path ${FIXTURE_PRIVATE_LINUX_PATH}
EOF

python3 "${REPO_ROOT}/scripts/stage-xcode-diagnostic.py" \
  --raw-log "${RAW_LOG}" \
  --output-dir "${ARCHIVE_DIAGNOSTIC_DIR}" \
  --exit-status 65 \
  --phase archive \
  --protected-values-file "${PROTECTED_VALUES}"

[[ "$(cat "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-exit-status.txt")" == 65 ]]
grep -F "error: use of undeclared identifier 'QWFixtureCompilerFailure'" "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'Undefined symbols for architecture arm64:' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F "error: The project 'Unity-iPhone' does not contain a scheme named 'FixtureScheme'." "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'Provisioning profile "Fixture Ad Hoc"' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'com.apple.developer.associated-domains entitlement' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'error: Signing certificate "Apple Distribution" is not trusted.' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '<GITHUB_WORKSPACE>' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '<RUNNER_TEMP>' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '<HOME>' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '<PRIVATE_LINUX_ABSOLUTE_PATH>' "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
! grep -F "${FIXTURE_PRIVATE_LINUX_PATH}" "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"

python3 - "${ARCHIVE_DIAGNOSTIC_DIR}" "${PROTECTED_VALUES}" "${RUNNER_TEMP}" "${HOME}" "${GITHUB_WORKSPACE}" "${FIXTURE_PRIVATE_LINUX_PATH}" <<'PY'
import json, re, sys
from pathlib import Path
out = Path(sys.argv[1])
protected = [value for value in Path(sys.argv[2]).read_bytes().split(b"\0") if value]
staged = b"\n".join(path.read_bytes() for path in sorted(out.iterdir()))
for value in protected + [value.encode() for value in sys.argv[3:]]:
    assert value not in staged
assert not re.search(rb'(?<![A-Za-z0-9_.-])/home/[A-Za-z0-9_.-]+/', staged)
summary = json.loads((out / "summary.json").read_text())
assert summary["phase"] == "archive"
assert summary["xcodebuildExitStatus"] == 65
assert summary["sanitizationProof"] == "PASS"
assert summary["sanitizedLogByteLength"] > 0
PY

# GREEN: exportArchive fails after archive context was already appended to the same protected log.
cat >> "${RAW_LOG}" <<EOF
** ARCHIVE SUCCEEDED **
Exporting archive with signing certificate "Apple Distribution"
error: exportArchive fixture retained underlying Xcode export failure
error: exportArchive: No profiles for 'com.wellmadesystems.quietworlds' were found
Authorization: Basic ${FIXTURE_TOKEN}
private export URL ${FIXTURE_URL}
private absolute path ${RUNNER_TEMP}/qw-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}/QuietWorlds.xcarchive
EOF

python3 "${REPO_ROOT}/scripts/stage-xcode-diagnostic.py" \
  --raw-log "${RAW_LOG}" \
  --output-dir "${EXPORT_DIAGNOSTIC_DIR}" \
  --exit-status 70 \
  --phase export \
  --protected-values-file "${PROTECTED_VALUES}"

[[ "$(cat "${EXPORT_DIAGNOSTIC_DIR}/xcodebuild-exit-status.txt")" == 70 ]]
grep -F "error: use of undeclared identifier 'QWFixtureCompilerFailure'" "${EXPORT_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F '** ARCHIVE SUCCEEDED **' "${EXPORT_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F 'error: exportArchive fixture retained underlying Xcode export failure' "${EXPORT_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"
grep -F "error: exportArchive: No profiles for 'com.wellmadesystems.quietworlds' were found" "${EXPORT_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log"

python3 - "${EXPORT_DIAGNOSTIC_DIR}" "${PROTECTED_VALUES}" "${RUNNER_TEMP}" "${HOME}" "${GITHUB_WORKSPACE}" "${FIXTURE_PRIVATE_LINUX_PATH}" <<'PY'
import json, re, sys
from pathlib import Path
out = Path(sys.argv[1])
protected = [value for value in Path(sys.argv[2]).read_bytes().split(b"\0") if value]
staged = b"\n".join(path.read_bytes() for path in sorted(out.iterdir()))
for value in protected + [value.encode() for value in sys.argv[3:]]:
    assert value not in staged
assert not re.search(rb'(?<![A-Za-z0-9_.-])/home/[A-Za-z0-9_.-]+/', staged)
text = staged.decode("utf-8", errors="replace")
assert not re.search(r"(?i)https?://", text)
authorization_lines = [line.strip() for line in text.splitlines() if re.match(r"(?i)^\s*authorization\s*:", line)]
assert all("Basic" not in line and "Bearer" not in line for line in authorization_lines), authorization_lines
summary = json.loads((out / "summary.json").read_text())
assert summary["phase"] == "export"
assert summary["xcodebuildExitStatus"] == 70
assert summary["sanitizationProof"] == "PASS"
assert summary["sanitizedLogByteLength"] > 0
PY

python3 - "${REPO_ROOT}/scripts/build-sign-return.sh" <<'PY'
import re, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
pattern = re.compile(
    r'set \+e\n'
    r'xcodebuild -exportArchive -archivePath "\$\{ARCHIVE_PATH\}" \\\n'
    r'  -exportPath "\$\{IPA_DIR\}" -exportOptionsPlist "\$\{EXPORT_OPTIONS\}" >>"\$\{XCODE_LOG\}" 2>&1\n'
    r'XCODEBUILD_EXPORT_STATUS=\$\?\n'
    r'set -e\n'
    r'if \[\[ "\$\{XCODEBUILD_EXPORT_STATUS\}" -ne 0 \]\]; then\n'
    r'.*?--exit-status "\$\{XCODEBUILD_EXPORT_STATUS\}" --phase export \\\n'
    r'.*?complete sanitized export diagnostic staged outside cleanup root.*?\n'
    r'  exit 7\nfi',
    re.S,
)
assert pattern.search(source), "export wrapper does not capture/stage the real export status"
assert source.count('xcodebuild -exportArchive -archivePath "${ARCHIVE_PATH}"') == 1
PY

bash "${REPO_ROOT}/scripts/cleanup.sh"
[[ ! -e "${ROOT}" ]]
[[ ! -e "${PROFILE_DEST}" ]]
[[ -s "${ARCHIVE_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log" ]]
[[ -s "${ARCHIVE_DIAGNOSTIC_DIR}/summary.json" ]]
[[ -s "${EXPORT_DIAGNOSTIC_DIR}/xcodebuild-sanitized.log" ]]
[[ -s "${EXPORT_DIAGNOSTIC_DIR}/summary.json" ]]
printf 'PASS RED log-loss fixture and GREEN archive/export diagnostic sanitization/survival/cleanup fixtures\n'
