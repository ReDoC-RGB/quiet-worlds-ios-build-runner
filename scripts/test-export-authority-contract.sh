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
 'archiveSha256':'e9b5e4712017c57d1c53e73b8a70bc34acfc85cf86279fb375d8771276322278',
 'manifestSha256':'7359be44293bf0420a1e4743a405b02eb895c2d7adc25b2d24c6a0f68a00e2d6',
 'manifestByteLength':626486,
 'inventoryCount':2996,
 'framedTreeSha256':'53b075bfa2684f460682bd08883696aba71c7d093827d5e112a7f04dfb88de6a',
 'candidateCommit':'90b4fe64bf2db71d718a7aad1fd9d75837ac6eda',
 'candidateTree':'ce29d091418f9d49bf79647fe70bf77315cd07b5',
}
if x!=expected: raise SystemExit('tracked final export authority mismatch')
for token in ['release-authority.json',"'archiveSha256':os.environ['QW_EXPORT_SHA256']","'manifestSha256':os.environ['QW_EXPORT_MANIFEST_SHA256']","'inventoryCount':int(os.environ['QW_EXPORT_INVENTORY_COUNT'])","'candidateCommit':os.environ['QW_CANDIDATE_COMMIT']"]:
 if token not in s: raise SystemExit('runner missing tracked authority binding: '+token)
PY
printf 'PASS exact export authority is tracked-commit-bound, protected-input-bound, and predecessor literals are absent\n'
