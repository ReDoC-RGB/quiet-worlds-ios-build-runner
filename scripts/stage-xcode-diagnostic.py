#!/usr/bin/env python3
"""Stage a complete sanitized Xcode failure diagnostic outside the cleanup root."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-log", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--exit-status", required=True, type=int)
    parser.add_argument("--phase", required=True, choices=("archive", "export"))
    parser.add_argument("--protected-values-file", required=True)
    args = parser.parse_args()

    raw_log = Path(args.raw_log)
    output_dir = Path(args.output_dir)
    protected_file = Path(args.protected_values_file)
    if args.exit_status == 0:
        raise SystemExit("refusing diagnostic staging for a successful command")
    if not raw_log.is_file() or raw_log.stat().st_size == 0:
        raise SystemExit("missing or empty private Xcode log")
    if not protected_file.is_file():
        raise SystemExit("protected-value authority file is missing")

    raw = raw_log.read_bytes()
    protected_values = sorted(
        {value for value in protected_file.read_bytes().split(b"\0") if value},
        key=len,
        reverse=True,
    )
    path_values: list[tuple[bytes, bytes]] = []
    for name, placeholder in (
        ("RUNNER_TEMP", b"<RUNNER_TEMP>"),
        ("GITHUB_WORKSPACE", b"<GITHUB_WORKSPACE>"),
        ("HOME", b"<HOME>"),
    ):
        value = os.environ.get(name, "")
        if not value or not os.path.isabs(value):
            raise SystemExit(f"{name} must be an absolute path")
        path_values.append((value.encode(), placeholder))
    path_values.sort(key=lambda item: len(item[0]), reverse=True)

    sanitized = raw
    for value, placeholder in path_values:
        sanitized = sanitized.replace(value, placeholder)
    for value in protected_values:
        sanitized = sanitized.replace(value, b"<PROTECTED_VALUE>")

    text = sanitized.decode("utf-8", errors="replace")
    text = re.sub(
        r"(?im)^[ \t]*authorization[ \t]*:[^\r\n]*",
        "Authorization: <PROTECTED_VALUE>",
        text,
    )
    text = re.sub(r"(?i)https?://[^\s\"'<>]+", "<URL>", text)
    text = re.sub(
        r"(?<![A-Za-z0-9_.-])/home/[A-Za-z0-9_.-]+(?:/[^\s:\"'<>]+)+",
        "<PRIVATE_LINUX_ABSOLUTE_PATH>",
        text,
    )
    sanitized = text.encode("utf-8")
    if not sanitized:
        raise SystemExit("sanitized Xcode log is empty")

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, mode=0o700)
    log_path = output_dir / "xcodebuild-sanitized.log"
    status_path = output_dir / "xcodebuild-exit-status.txt"
    summary_path = output_dir / "summary.json"
    log_path.write_bytes(sanitized)
    status_path.write_text(f"{args.exit_status}\n", encoding="utf-8")
    summary = {
        "schema": 1,
        "status": "FAIL",
        "phase": args.phase,
        "xcodebuildExitStatus": args.exit_status,
        "rawLogSha256": sha256(raw),
        "sanitizedLogSha256": sha256(sanitized),
        "sanitizedLogByteLength": len(sanitized),
        "workflowRunId": os.environ.get("GITHUB_RUN_ID"),
        "workflowRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "runnerCommit": os.environ.get("GITHUB_SHA"),
        "sanitizationProof": "PASS",
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for path in output_dir.iterdir():
        os.chmod(path, 0o600)

    staged = b"\n".join(path.read_bytes() for path in sorted(output_dir.iterdir()))
    forbidden = [value for value, _ in path_values] + protected_values
    if any(value in staged for value in forbidden):
        shutil.rmtree(output_dir)
        raise SystemExit("exact protected value remained in staged diagnostic bytes")
    staged_text = staged.decode("utf-8", errors="replace")
    if re.search(r"(?im)^[ \t]*authorization[ \t]*:(?![ \t]*<PROTECTED_VALUE>)", staged_text):
        shutil.rmtree(output_dir)
        raise SystemExit("Authorization header remained in staged diagnostic bytes")
    if re.search(r"(?i)https?://", staged_text):
        shutil.rmtree(output_dir)
        raise SystemExit("URL remained in staged diagnostic bytes")
    if re.search(r"(?<![A-Za-z0-9_.-])/home/[A-Za-z0-9_.-]+/", staged_text):
        shutil.rmtree(output_dir)
        raise SystemExit("private Linux absolute path remained in staged diagnostic bytes")


if __name__ == "__main__":
    main()
