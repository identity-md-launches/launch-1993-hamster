#!/usr/bin/env python3
"""Offline ABI check after `forge build`; uses only Python's standard library."""

import json
from pathlib import Path


def shape(value):
    """Names do not affect ABI encoding, but order, types and mutability do."""
    if isinstance(value, dict):
        return {key: shape(item) for key, item in value.items() if key not in ("name", "internalType")}
    if isinstance(value, list):
        return [shape(item) for item in value]
    return value


root = Path(__file__).resolve().parent.parent
reference = json.loads((root / "docs/reference/HamsterHour.reads.abi.json").read_text())
compiled = json.loads((root / "out/IHamsterHour.sol/IHamsterHour.json").read_text())["abi"]
for expected in reference:
    candidates = [item for item in compiled if item.get("name") == expected.get("name") and item["type"] == expected["type"]]
    if len(candidates) != 1 or shape(candidates[0]) != shape(expected):
        raise SystemExit(f"ABI mismatch: {expected['name']}")
    print(f"{expected['name']}: matches published ABI")
