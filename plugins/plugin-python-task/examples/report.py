"""Example of consuming mapped options and valueless flags with argparse."""

import argparse
import json


def main() -> None:
    """Parse options as data and print them for Compose verification."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--customer", required=True)
    parser.add_argument("--output", default="report.csv")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    print(json.dumps(vars(arguments), ensure_ascii=False))


if __name__ == "__main__":
    main()
