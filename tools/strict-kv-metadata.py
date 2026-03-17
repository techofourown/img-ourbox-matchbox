#!/usr/bin/env python3
import argparse
import json
import pathlib
import re
import sys


LINE_RE = re.compile(r"^([A-Z0-9_]+)=([A-Za-z0-9_./:@%+,=~-]*)$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Parse strict KEY=VALUE metadata without executing shell code."
    )
    parser.add_argument("path", help="Metadata file to parse")
    parser.add_argument(
        "--allow",
        action="append",
        default=[],
        help="Allow this key in the metadata surface",
    )
    parser.add_argument(
        "--require",
        action="append",
        default=[],
        help="Require this key to be present",
    )
    parser.add_argument(
        "--print",
        dest="print_keys",
        action="append",
        default=[],
        help="Print this key's value in the requested order",
    )
    parser.add_argument(
        "--json",
        dest="json_output",
        action="store_true",
        help="Emit the parsed map as JSON instead of newline-delimited values",
    )
    return parser.parse_args()


def die(message: str) -> None:
    raise SystemExit(message)


def main() -> int:
    args = parse_args()
    path = pathlib.Path(args.path)
    if not path.is_file():
        die(f"metadata file not found: {path}")

    allowed_keys = set(args.allow) | set(args.require) | set(args.print_keys)
    values: dict[str, str] = {}

    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if raw_line == "" or raw_line.startswith("#"):
            continue
        if raw_line.startswith("export "):
            die(f"{path}:{line_number}: export syntax is not allowed")
        match = LINE_RE.fullmatch(raw_line)
        if not match:
            die(f"{path}:{line_number}: invalid metadata line")
        key, value = match.groups()
        if key in values:
            die(f"{path}:{line_number}: duplicate key: {key}")
        if allowed_keys and key not in allowed_keys:
            die(f"{path}:{line_number}: unexpected key: {key}")
        values[key] = value

    missing_keys = [key for key in args.require if key not in values]
    if missing_keys:
        die(f"{path}: missing required keys: {', '.join(missing_keys)}")

    if args.json_output:
        json.dump(values, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    if args.print_keys:
        for key in args.print_keys:
            sys.stdout.write(f"{values.get(key, '')}\n")
        return 0

    for key in sorted(values):
        sys.stdout.write(f"{key}={values[key]}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
