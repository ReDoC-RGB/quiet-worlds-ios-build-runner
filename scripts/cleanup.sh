#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
ROOT="${RUNNER_TEMP}/qw-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
KEYCHAIN="${ROOT}/quiet-worlds.keychain-db"
PROFILE_RECORD="${ROOT}/installed-profile-path.txt"
if [[ -f "${PROFILE_RECORD}" ]]; then
  PROFILE_DEST="$(cat "${PROFILE_RECORD}")"
  case "${PROFILE_DEST}" in
    "${HOME}/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision) rm -f -- "${PROFILE_DEST}" ;;
    *) printf 'refusing unexpected provisioning profile cleanup path\n' >&2 ;;
  esac
fi
if [[ -e "${KEYCHAIN}" ]]; then
  security delete-keychain "${KEYCHAIN}" >/dev/null 2>&1 || true
fi
rm -rf -- "${ROOT}"
printf 'PASS transient keychain, provisioning profile, credentials, payload, IPA, and logs removed\n'
