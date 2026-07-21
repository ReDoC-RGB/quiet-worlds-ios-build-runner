#!/usr/bin/env bash
set -euo pipefail
f="$(cd "$(dirname "$0")" && pwd)/build-sign-return.sh"
counter="$(cd "$(dirname "$0")" && pwd)/count-signing-identities.sh"
grep -F 'chmod 0600 "${P12}" "${PROFILE}"' "$f"
grep -F 'security set-key-partition-list -S apple-tool:,apple:' "$f"
! grep -F 'codesign:' "$f"
grep -F 'openssl pkcs12 -in "${P12}"' "$f"
grep -F "P12_CERT_SHA1=\"\$(shasum -a 1 \"\${P12_CERT_DER}\" | cut -d ' ' -f 1 | tr '[:lower:]' '[:upper:]')\"" "$f"
grep -F 'if ! IDENTITY_OUTPUT="$(security find-identity -v -p codesigning "${KEYCHAIN}")"; then' "$f"
grep -F 'unable to enumerate usable distribution identities' "$f"
grep -F 'usable distribution identity mismatch: expected 1, found %s' "$f"
! grep -F 'security find-identity -v -p codesigning "${KEYCHAIN}" | grep' "$f"
grep -F 'CODE_SIGN_IDENTITY="${P12_CERT_SHA1}"' "$f"
grep -F 'OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN}"' "$f"

lower=abcdef0123456789abcdef0123456789abcdef01
upper=ABCDEF0123456789ABCDEF0123456789ABCDEF01
other=1111111111111111111111111111111111111111
[[ "$(printf '  1) %s "Fixture"\n' "$upper" | "$counter" "$lower")" == 1 ]]
[[ "$(printf '  1) %s "Fixture"\n' "$lower" | "$counter" "$upper")" == 1 ]]
[[ "$(printf '  1) %s "Other"\n' "$other" | "$counter" "$lower")" == 0 ]]
[[ "$(printf '  1) %s "First"\n  2) %s "Second"\n' "$upper" "$lower" | "$counter" "$lower")" == 2 ]]
! printf '' | "$counter" invalid >/dev/null 2>&1
echo 'PASS focused signing bootstrap contract'
