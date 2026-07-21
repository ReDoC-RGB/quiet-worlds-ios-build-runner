#!/usr/bin/env bash
# Shared post-IPA checkpoint runner. The caller must define DIAGNOSTIC_DIR,
# POST_IPA_LOG, PROTECTED_VALUES_FILE, GITHUB_WORKSPACE, GITHUB_RUN_ID, and GITHUB_SHA.

qw_stage_post_ipa_failure() {
  local checkpoint="$1"
  local status="$2"
  if python3 "${GITHUB_WORKSPACE}/scripts/stage-post-ipa-diagnostic.py" \
    --raw-log "${POST_IPA_LOG}" \
    --output-dir "${DIAGNOSTIC_DIR}" \
    --checkpoint "${checkpoint}" \
    --status "${status}" \
    --protected-values-file "${PROTECTED_VALUES_FILE}"; then
    return 0
  fi

  # Fail closed with the mandatory bounded summary even if diagnostic sanitization fails.
  rm -rf -- "${DIAGNOSTIC_DIR}"
  mkdir -p "${DIAGNOSTIC_DIR}"
  chmod 0700 "${DIAGNOSTIC_DIR}"
  python3 - "${DIAGNOSTIC_DIR}/summary.json" "${checkpoint}" "${status}" <<'PY'
import json, os, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "workflowRunId": os.environ.get("GITHUB_RUN_ID", ""),
    "runnerCommit": os.environ.get("GITHUB_SHA", ""),
    "checkpoint": sys.argv[2],
    "status": int(sys.argv[3]),
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  chmod 0600 "${DIAGNOSTIC_DIR}/summary.json"
}

qw_run_checkpoint() {
  local checkpoint="$1"
  shift
  local status
  printf 'CHECKPOINT %s START\n' "${checkpoint}"
  : > "${POST_IPA_LOG}"
  set +e
  "$@" >"${POST_IPA_LOG}" 2>&1
  status=$?
  set -e
  printf 'CHECKPOINT %s status=%s\n' "${checkpoint}" "${status}"
  if [[ "${status}" -ne 0 ]]; then
    qw_stage_post_ipa_failure "${checkpoint}" "${status}"
    exit "${status}"
  fi
}
