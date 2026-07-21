#!/usr/bin/env bash
set -euo pipefail
f="$(cd "$(dirname "$0")" && pwd)/build-sign-return.sh"
grep -F 'chmod 0600 "${P12}" "${PROFILE}"' "$f"
grep -F 'security set-key-partition-list -S apple-tool:,apple:' "$f"
! grep -F 'codesign:' "$f"
grep -F 'openssl pkcs12 -in "${P12}"' "$f"
grep -F 'P12_CERT_SHA1=' "$f"
grep -F 'IDENTITY_COUNT=' "$f"
grep -F 'CODE_SIGN_IDENTITY="${P12_CERT_SHA1}"' "$f"
grep -F 'OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN}"' "$f"
echo 'PASS focused signing bootstrap contract'
