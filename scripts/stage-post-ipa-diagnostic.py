#!/usr/bin/env python3
"""Stage a bounded, sanitized post-IPA failure diagnostic outside cleanup roots."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
from pathlib import Path

CHECKPOINTS = {
    "extract_ipa",
    "locate_app",
    "verify_codesign",
    "extract_signing_certificate",
    "verify_certificate_continuity",
    "verify_arm64",
    "verify_ipa_identity",
    "stage_result",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-log", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--checkpoint", required=True, choices=sorted(CHECKPOINTS))
    parser.add_argument("--status", required=True, type=int)
    parser.add_argument("--protected-values-file", required=True)
    args = parser.parse_args()

    if args.status == 0:
        raise SystemExit("refusing diagnostic staging for a successful checkpoint")
    raw_log = Path(args.raw_log)
    protected_file = Path(args.protected_values_file)
    if not raw_log.is_file() or not protected_file.is_file():
        raise SystemExit("diagnostic input authority is missing")

    protected = sorted(
        {value for value in protected_file.read_bytes().split(b"\0") if value},
        key=len,
        reverse=True,
    )
    sanitized = raw_log.read_bytes()
    path_values: list[bytes] = []
    for name in ("RUNNER_TEMP", "GITHUB_WORKSPACE", "HOME"):
        value = os.environ.get(name, "")
        if value and os.path.isabs(value):
            encoded = value.encode()
            path_values.append(encoded)
            sanitized = sanitized.replace(encoded, f"<{name}>".encode())
    for value in protected:
        sanitized = sanitized.replace(value, b"<PROTECTED_VALUE>")

    text = sanitized.decode("utf-8", errors="replace")
    text = re.sub(r"(?im)^[ \t]*authorization[ \t]*:[^\r\n]*", "Authorization: ***", text)
    text = re.sub(r"(?i)https?://[^\s\"'<>]+", "<URL>", text)
    text = re.sub(
        r"(?<![A-Za-z0-9_.-])/(?:Users|home|root)/[^\s:\"'<>]+",
        "<PRIVATE_ABSOLUTE_PATH>",
        text,
    )
    text = re.sub(
        r"(?<![A-Za-z0-9_.-])/private/var/[^\s:\"'<>]+",
        "<PRIVATE_ABSOLUTE_PATH>",
        text,
    )
    text = re.sub(
        r"(?i)(?<![A-Za-z0-9_.-])[A-Z]:\\(?:Users|Documents and Settings)\\[^\r\n\"'<>]+",
        "<PRIVATE_ABSOLUTE_PATH>",
        text,
    )
    sanitized = text.encode("utf-8")

    output_dir = Path(args.output_dir)
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, mode=0o700)
    summary = {
        "workflowRunId": os.environ.get("GITHUB_RUN_ID", ""),
        "runnerCommit": os.environ.get("GITHUB_SHA", ""),
        "checkpoint": args.checkpoint,
        "status": args.status,
    }
    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    if sanitized:
        (output_dir / "command-output-sanitized.log").write_bytes(sanitized)
    for path in output_dir.iterdir():
        os.chmod(path, 0o600)

    staged = b"\n".join(path.read_bytes() for path in sorted(output_dir.iterdir()))
    forbidden = protected + path_values
    staged_text = staged.decode("utf-8", errors="replace")
    unsafe = (
        any(value in staged for value in forbidden)
        or re.search(r"(?i)https?://", staged_text)
        or re.search(r"(?<![A-Za-z0-9_.-])/(?:Users|home|root)/", staged_text)
        or re.search(r"(?<![A-Za-z0-9_.-])/private/var/", staged_text)
        or re.search(r"(?i)(?<![A-Za-z0-9_.-])[A-Z]:\\(?:Users|Documents and Settings)\\", staged_text)
    )
    if unsafe:
        shutil.rmtree(output_dir)
        raise SystemExit("protected value or private absolute path remained in diagnostic")


if __name__ == "__main__":
    main()
