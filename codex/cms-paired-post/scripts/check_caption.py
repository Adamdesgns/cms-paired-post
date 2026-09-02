#!/usr/bin/env python3
"""Validate a CMS Paired Post caption without third-party dependencies."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


CASHTAG_RE = re.compile(r"(?<![\w])\$[A-Za-z][A-Za-z0-9._-]*")
WORD_RE = re.compile(r"\$[A-Za-z][A-Za-z0-9._-]*|[^\W_]+(?:[’'][^\W_]+)?", re.UNICODE)


def words(text: str) -> list[str]:
    return [match.group(0).lower() for match in WORD_RE.finditer(text)]


def six_word_runs(text: str) -> set[str]:
    tokens = words(text)
    return {" ".join(tokens[index : index + 6]) for index in range(max(0, len(tokens) - 5))}


def read_caption(args: argparse.Namespace) -> str:
    if args.caption is not None:
        return args.caption
    return args.caption_file.read_text(encoding="utf-8-sig")


def check_corpus(candidate_runs: set[str], corpus: Path) -> list[str]:
    problems: list[str] = []
    if not corpus.is_file():
        return [f"Corpus does not exist: {corpus}"]

    with corpus.open("r", encoding="utf-8-sig") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                problems.append(f"Invalid JSONL at line {line_number}: {error.msg}")
                continue
            source_text = record.get("exact_text")
            if not isinstance(source_text, str):
                problems.append(f"Corpus line {line_number} has no string exact_text field.")
                continue
            overlap = sorted(candidate_runs.intersection(six_word_runs(source_text)))
            item = record.get("item", line_number)
            problems.extend(f"Six-word source overlap with item {item}: '{run}'." for run in overlap)
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--caption", help="Caption text to validate.")
    source.add_argument("--caption-file", type=Path, help="UTF-8 text file containing the caption.")
    parser.add_argument("--corpus", type=Path, help="Optional JSONL corpus with exact_text fields.")
    parser.add_argument("--manual-scoreboard", action="store_true", help="Allow more than one cashtag for a manually reviewed scoreboard.")
    args = parser.parse_args()

    caption = read_caption(args)
    cashtags = sorted({value.upper() for value in CASHTAG_RE.findall(caption)})
    problems: list[str] = []

    if len(caption) > 280:
        problems.append(f"Caption is {len(caption)} characters; maximum is 280.")
    if re.search(r"\bcomment\s+yes\b", caption, re.IGNORECASE):
        problems.append("Caption uses the forbidden Comment YES CTA.")
    if "```" in caption:
        problems.append("Caption contains a triple-backtick fence.")
    if not args.manual_scoreboard and len(cashtags) > 1:
        problems.append(f"Caption contains {len(cashtags)} cashtags; standard posts allow at most one.")

    overlap_status = "overlap check skipped (no corpus supplied)"
    if args.corpus is not None:
        problems.extend(check_corpus(six_word_runs(caption), args.corpus))
        overlap_status = "six-word overlap checked"

    if problems:
        for problem in dict.fromkeys(problems):
            print(f"FAIL: {problem}", file=sys.stderr)
        return 1

    print(f"PASS: {len(caption)} characters, {len(cashtags)} cashtag(s), {overlap_status}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
