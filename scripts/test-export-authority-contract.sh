#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo/.github/workflows/build-ios-adhoc.yml"
runner="$repo/scripts/build-sign-return.sh"
authority="$repo/release-authority.json"
required=(QW_EXPORT_MANIFEST_SHA256 QW_EXPORT_INVENTORY_COUNT QW_EXPORT_FRAMED_TREE_SHA256 QW_CANDIDATE_COMMIT QW_CANDIDATE_TREE)
for name in "${required[@]}"; do
  grep -Fq "$name" "$workflow" || { printf 'workflow missing exact authority input %s\n' "$name" >&2; exit 1; }
  grep -Fq "$name" "$runner" || { printf 'runner missing exact authority validation %s\n' "$name" >&2; exit 1; }
done
for stale in \
  0e403576d598dc32651fdddc310b35f9b975d9bb4f3827f7887992517f23573a \
  a17b8559f4ad514f9aedc1872d1d72138f62edd1730c50175818e2146ff51b2d \
  67480c6503122c10ef7477f22e0bcc8cb94e12a85a73246dd5044ced169e59a2 \
  43495c92a9697ad652dbd354cb9f333ffb833c8a \
  a20b2d6f94e0cdae20ff4fb9b73af253156c9ac1 \
  "len(x['fileInventory'])==3013" \
  62740c60118f9867ac787baadfb8058f935ded317c9d8dc1b4f871bc010c68dd \
  486a64ce469a5e6c61564633ab43a3ce04a9d3aa78de62005063e471b5c75a6b \
  936aec62751d6b9fe183ca0875bdf37bfc1e8dfa557bbff479b2f88735ac09fd \
  fe4c8b2a6da3d582108851452975dd2cb6491c59 \
  3a963754b00a7f95f95912c48f627265543b2708 \
  "len(x['fileInventory'])==2996"; do
  if grep -Fq "$stale" "$runner"; then
    printf 'runner retains predecessor export authority: %s\n' "$stale" >&2
    exit 1
  fi
done
python3 - "$runner" "$authority" <<'PY'
import json
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
checks=[
 "x['candidateCommit']==os.environ['QW_CANDIDATE_COMMIT']",
 "x['candidateTree']==os.environ['QW_CANDIDATE_TREE']",
 "len(x['fileInventory'])==int(os.environ['QW_EXPORT_INVENTORY_COUNT'])",
 "x['framedTreeSha256']==os.environ['QW_EXPORT_FRAMED_TREE_SHA256']",
]
missing=[c for c in checks if c not in s]
if missing: raise SystemExit('missing fail-closed exact authority checks: '+repr(missing))
x=json.loads(Path(sys.argv[2]).read_text())
expected={
 'schema':1,
 'archiveSha256':'195644d077ab34467a74a0680b45d7468c791116e387482c0099e81016ebab8a',
 'manifestSha256':'f8933df9aefa5554d50a191936a6c6a849b90405854ebe18ede33ca91878cc52',
 'manifestByteLength':631476,
 'inventoryCount':3020,
 'framedTreeSha256':'cdebba9bbdbbc3700b4f8ac712fbe916d1a48cd61422edc1a89d0fd553471082',
 'candidateCommit':'9b042f7dfa7a9a9a68f9d11f56d159814042f0ae',
 'candidateTree':'f85b6e0d9f55c2405b5803cb51b6133e64b666ce',
}
if x!=expected: raise SystemExit('tracked final export authority mismatch')
for token in ['release-authority.json',"'archiveSha256':os.environ['QW_EXPORT_SHA256']","'manifestSha256':os.environ['QW_EXPORT_MANIFEST_SHA256']","'inventoryCount':int(os.environ['QW_EXPORT_INVENTORY_COUNT'])","'candidateCommit':os.environ['QW_CANDIDATE_COMMIT']"]:
 if token not in s: raise SystemExit('runner missing tracked authority binding: '+token)
PY
printf 'PASS exact export authority is tracked-commit-bound, protected-input-bound, and predecessor literals are absent\n'
