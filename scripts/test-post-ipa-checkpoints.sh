#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${REPO_ROOT}/scripts/build-sign-return.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "${FIXTURE}"' EXIT
export RUNNER_TEMP="${FIXTURE}/runner-temp"
export HOME="${FIXTURE}/home"
export GITHUB_WORKSPACE="${REPO_ROOT}"
export GITHUB_RUN_ID=101010
export GITHUB_RUN_ATTEMPT=1
export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "${RUNNER_TEMP}" "${HOME}"
PROTECTED_VALUES_FILE="${FIXTURE}/protected-values.nul"
printf '%s\0' 'fixture-secret-protected-value' 'https://private.invalid/opaque' >"${PROTECTED_VALUES_FILE}"
POST_IPA_LOG="${FIXTURE}/post-ipa.log"
# shellcheck source=scripts/post-ipa-checkpoints.sh
source "${REPO_ROOT}/scripts/post-ipa-checkpoints.sh"

python3 - "${BUILD}" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
safety = 'verify-ipa-archive --ipa "${IPA}"'
extract = 'qw_run_checkpoint extract_ipa unzip -q "${IPA}" -d "${VERIFY_ROOT}"'
assert text.count(safety) == 1
assert text.count(extract) == 1
assert text.index(safety) < text.index(extract)
assert 'ditto -x -k' not in text
assert re.findall(r'\bPRODUCT_BUNDLE_IDENTIFIER(?:_[A-Za-z0-9_]+)?=', text[text.index('xcodebuild "${XCODE_CONTAINER_ARGS[@]}"'):text.index('XCODEBUILD_STATUS=$?')]) == []
assert text.count('PROVISIONING_PROFILE_SPECIFIER_APP="${PROFILE_NAME}"') == 1
checkpoints = [
    'extract_ipa', 'locate_app', 'verify_codesign', 'extract_signing_certificate',
    'verify_certificate_continuity', 'verify_arm64', 'verify_ipa_identity', 'stage_result',
]
for checkpoint in checkpoints:
    assert text.count(f'qw_run_checkpoint {checkpoint} ') == 1
print('PASS static post-IPA ordering/extractor/checkpoint contract')
PY

SAFE_IPA="${FIXTURE}/safe.ipa"
SAFE_OUT="${FIXTURE}/safe-out"
python3 - "${SAFE_IPA}" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('Payload/', b'')
    z.writestr('Payload/Fixture.app/', b'')
    z.writestr('Payload/Fixture.app/Info.plist', b'fixture')
PY
python3 "${REPO_ROOT}/scripts/verify-public-runner.py" verify-ipa-archive --ipa "${SAFE_IPA}"
unzip -q "${SAFE_IPA}" -d "${SAFE_OUT}"
[[ -f "${SAFE_OUT}/Payload/Fixture.app/Info.plist" ]]
printf 'PASS representative safe IPA extracted with unzip -q\n'

# A malformed archive must report extract_ipa instead of exiting silently.
BROKEN_IPA="${FIXTURE}/broken.ipa"
printf 'not a zip\n' >"${BROKEN_IPA}"
DIAGNOSTIC_DIR="${FIXTURE}/diagnostic-extract"
set +e
(
  set -euo pipefail
  qw_run_checkpoint extract_ipa unzip -q "${BROKEN_IPA}" -d "${FIXTURE}/broken-out"
) >"${FIXTURE}/extract-checkpoint.out" 2>&1
status=$?
set -e
[[ "${status}" -ne 0 ]]
grep -F 'CHECKPOINT extract_ipa status=' "${FIXTURE}/extract-checkpoint.out"
python3 - "${DIAGNOSTIC_DIR}" <<'PY'
import json, sys
from pathlib import Path
out=Path(sys.argv[1]); summary=json.loads((out/'summary.json').read_text())
assert summary['checkpoint']=='extract_ipa' and isinstance(summary['status'], int) and summary['status'] != 0
assert set(summary)=={'workflowRunId','runnerCommit','checkpoint','status'}
assert (out/'command-output-sanitized.log').stat().st_size > 0
PY

# Every later checkpoint must retain its exact name and sanitized command output.
for checkpoint in locate_app verify_codesign extract_signing_certificate verify_certificate_continuity verify_arm64 verify_ipa_identity stage_result; do
  DIAGNOSTIC_DIR="${FIXTURE}/diagnostic-${checkpoint}"
  set +e
  (
    set -euo pipefail
    qw_run_checkpoint "${checkpoint}" bash -c 'printf "failure fixture-secret-protected-value https://private.invalid/opaque /home/private-builder/export/file C:\\Users\\Private\\file\n" >&2; exit 23'
  ) >"${FIXTURE}/${checkpoint}.out" 2>&1
  status=$?
  set -e
  [[ "${status}" == 23 ]]
  grep -F "CHECKPOINT ${checkpoint} status=23" "${FIXTURE}/${checkpoint}.out"
  python3 - "${DIAGNOSTIC_DIR}" "${checkpoint}" <<'PY'
import json,re,sys
from pathlib import Path
out=Path(sys.argv[1]); expected=sys.argv[2]
summary=json.loads((out/'summary.json').read_text())
assert summary=={
 'checkpoint':expected,'runnerCommit':'0123456789abcdef0123456789abcdef01234567',
 'status':23,'workflowRunId':'101010'}
staged=b'\n'.join(p.read_bytes() for p in sorted(out.iterdir()))
assert b'fixture-secret-protected-value' not in staged
assert b'private.invalid' not in staged
text=staged.decode(errors='replace')
assert not re.search(r'(?i)https?://',text)
assert '/home/private-builder/' not in text
assert not re.search(r'(?i)C:\\\\Users\\\\Private',text)
assert sorted(p.name for p in out.iterdir())==['command-output-sanitized.log','summary.json']
PY
done
printf 'PASS exact forced-failure checkpoint reporting and protected-value/private-path exclusion\n'
