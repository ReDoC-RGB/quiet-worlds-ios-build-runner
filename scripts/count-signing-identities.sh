#!/usr/bin/env bash
set -euo pipefail

[[ "$#" == 1 ]] || { printf 'usage: count-signing-identities.sh EXPECTED_SHA1\n' >&2; exit 2; }
EXPECTED_SHA1="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
[[ "${EXPECTED_SHA1}" =~ ^[0-9A-F]{40}$ ]] || { printf 'expected SHA-1 must be 40 hexadecimal characters\n' >&2; exit 2; }

count=0
while IFS= read -r line; do
  normalized_line="$(printf '%s' "${line}" | tr '[:lower:]' '[:upper:]')"
  if [[ "${normalized_line}" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]{40})([[:space:]]|$) ]] && [[ "${BASH_REMATCH[1]}" == "${EXPECTED_SHA1}" ]]; then
    count=$((count + 1))
  fi
done
printf '%s\n' "${count}"