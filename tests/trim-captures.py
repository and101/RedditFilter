#!/usr/bin/env python3
"""Makes the small, anonymous test responses in tests/fixtures from captured ones (see tests/replay.sh).

  tests/trim-captures.py <output folder> <capture.json>...

Only a response's shape is kept: its fields, type names, flags and nulls, and a few items of each list
(some ads, some not). Every other text, ID, link and number is replaced, so nothing says what was shown or to whom.
"""
import json
import os
import re
import sys

KEPT_TEXT = {"__typename", "type", "indicators"}  # the only texts the filter reads by value
CONSTANT_IDS = {"t2_6l4z3"}  # AutoModerator
TYPE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
KINDS = {"edges": 2, "children": 2, "trees": 2, "postsInfoByIds": 2}  # list: how many of each kind to keep


def is_ad(item):
    """Whether an item or its node is an ad, for keeping some of both."""
    if not isinstance(item, dict):
        return False
    node = item.get("node") if isinstance(item.get("node"), dict) else item
    return (
        isinstance(node.get("adPayload"), dict)
        or node.get("__typename") in ("AdPost", "SearchAdPost")
        or node.get("isCreatedFromAdsUi") is True
    )


def kind(item):
    node = item.get("node") if isinstance(item, dict) and isinstance(item.get("node"), dict) else item
    return (is_ad(item), node.get("__typename") if isinstance(node, dict) else None)


class Trimmer:
    def __init__(self):
        self.ids = {}

    def text(self, value, key):
        if key in KEPT_TEXT and TYPE_NAME.match(value):
            return value
        if value in CONSTANT_IDS:
            return value
        prefix = re.match(r"^(t\d)_\w+$", value)
        if prefix:
            return self.ids.setdefault(value, f"{prefix[1]}_{len(self.ids) + 1}")
        if key in ("id", "groupId"):
            return self.ids.setdefault(value, f"id{len(self.ids) + 1}")
        if not value:
            return value
        return "https://example.com/" if re.match(r"^https?://", value) else "text"

    def items(self, values, key):
        if key == "cells":
            return values  # which cells a card has decides whether it's a post
        most = KINDS.get(key)
        kept, seen = [], {}
        for value in values:
            group = kind(value) if most else None
            seen[group] = seen.get(group, 0) + 1
            if seen[group] <= (most or 2):
                kept.append(value)
        return kept

    def trim(self, value, key=None):
        if isinstance(value, dict):
            return {name: self.trim(inner, name) for name, inner in value.items()}
        if isinstance(value, list):
            return [self.trim(inner, key) for inner in self.items(value, key)]
        if isinstance(value, str):
            return self.text(value, key)
        if isinstance(value, (bool, type(None))):
            return value
        return 1


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    trimmer = Trimmer()  # shared, so an ad's card and its details keep the same ID
    for path in sys.argv[2:]:
        operation = re.split(r"[-.]", os.path.basename(path))[0]
        with open(path) as file:
            data = json.load(file).get("data")
        name, number = f"{operation}.json", 2
        while os.path.exists(os.path.join(folder, name)):
            name, number = f"{operation}-{number}.json", number + 1
        with open(os.path.join(folder, name), "w") as file:
            json.dump({"data": trimmer.trim(data)}, file, indent=1, ensure_ascii=True)
            file.write("\n")
        print(f"{name}: {os.path.getsize(os.path.join(folder, name))} bytes")


main()
