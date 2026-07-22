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
  fb9e2b95f5b5cef5eeef4852242d0261099597f1bb31a5ed10e2e2993a3f484e \
  82e6bd71b0dfbcdb80f61e342a41622e2212194e59c5877df84dec25ab420472 \
  f5b17cbbb1677533897ab6808de17df2e5fa594ff7b4ed2a2a07038f1a487860 \
  bf979035848d4f4258e119e823407e3963928a0c6b95c4a3f14272fdabc39468 \
  "len(x['fileInventory'])==2994"; do
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
 'archiveSha256':'1d4b5b8544ec5024883cd72f8e1722e2a21b131cabd1674481516387efbcb67f',
 'manifestSha256':'7ddc565f42c32b41b1f37fd63e94bf49c4e59e0b99df9eee436e0a7e51124ad2',
 'manifestByteLength':626282,
 'inventoryCount':2995,
 'framedTreeSha256':'6ea69a2ac4000553affa8aeaf65fbe3de4d8d2e475bac63e4bad425bd3afaa13',
 'candidateCommit':'b0a0309802de6ae5553660c0f54ee71b8073e9c2',
 'candidateTree':'47328c260cde7daa542e4f703c306f43e90d26a2',
}
if x!=expected: raise SystemExit('tracked final export authority mismatch')
for token in ['release-authority.json',"'archiveSha256':os.environ['QW_EXPORT_SHA256']","'manifestSha256':os.environ['QW_EXPORT_MANIFEST_SHA256']","'inventoryCount':int(os.environ['QW_EXPORT_INVENTORY_COUNT'])","'candidateCommit':os.environ['QW_CANDIDATE_COMMIT']"]:
 if token not in s: raise SystemExit('runner missing tracked authority binding: '+token)
PY
printf 'PASS exact export authority is tracked-commit-bound, protected-input-bound, and predecessor literals are absent\n'
