#!/usr/bin/env python3
"""Lists where a Reddit build's GraphQL fragments can hold ads, for tests/check-ipa.sh.

  tests/graphql-ads.py <file of strings from the app's binaries>

Prints three baseline sections:
  [ad-schema]     ad types and ad fields
  [ad-locations]  what asks for them: "fragment on Type: ad type, field or fragment"
  [feed-fields]   what feed and search cards ask for, as a card must keep every field its query names

Only fragments are in the app: whole operations are stored as hashes, so paths to a response's root
aren't here. This says what the app can ask for, not what Reddit sends.
"""
import re
import sys

# "Ad"/"Ads" as a word of its own in a camelCase name (AdPost, SKAdNetworkData, pdpCommentsAds, adPayload),
# not the start of another (Address, Adjust, Admin).
AD_NAME = re.compile(r"(?:^ads?|Ads?)(?=[A-Z0-9_]|$)|[Pp]romoted|[Ss]ponsor")
# Types the filter replaces, empties or removes items in.
CARD_TYPES = {
    "CellGroup", "CellInfo", "CrossPostCell", "FeedElement", "FeedElementConnection", "FeedElementEdge",
    "PostPreviewComponent", "SearchComponent", "SearchListComponent", "SearchGridComponent",
    "SearchMainConnection", "SearchPost", "SearchAdPost", "ConversationAdFeedUnit",
}
TOKEN = re.compile(r'\.\.\.|[A-Za-z_]\w*|"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|[{}()\[\]:@$!,=]')


class Parser:
    """Just enough GraphQL to read a fragment: (kind, name, condition, children) tuples."""

    def __init__(self, text):
        self.tokens, self.at = TOKEN.findall(text), 0

    def peek(self):
        return self.tokens[self.at] if self.at < len(self.tokens) else ""

    def take(self, expected=None):
        token = self.tokens[self.at]
        if expected and token != expected:
            raise ValueError(f"expected {expected}, got {token}")
        self.at += 1
        return token

    def arguments(self):
        if self.peek() != "(":
            return ""
        start, depth = self.at, 0
        while True:
            token = self.take()
            depth += (token == "(") - (token == ")")
            if not depth:
                return "".join(self.tokens[start : self.at])

    def directives(self):
        found = ""
        while self.peek() == "@":
            self.take()
            found += " @" + self.take() + self.arguments()
        return found

    def selections(self):
        found = []
        self.take("{")
        while self.peek() != "}":
            if self.peek() == ",":
                self.take()
            elif self.peek() == "...":
                self.take()
                if self.peek() in ("{", "@", "on"):
                    name = ""
                    if self.peek() == "on":
                        self.take()
                        name = self.take()
                    condition = self.directives()
                    found.append(("on", name, condition, self.selections()))
                else:
                    found.append(("spread", self.take(), self.directives(), []))
            else:
                name = self.take()
                if self.peek() == ":":  # alias: the response uses the alias
                    self.take()
                    name += "=" + self.take()
                self.arguments()
                condition = self.directives()
                found.append(("field", name, condition, self.selections() if self.peek() == "{" else []))
        self.take("}")
        return found

    def fragment(self):
        self.take("fragment")
        name = self.take()
        self.take("on")
        on = self.take()
        self.directives()
        return name, on, self.selections()


def flatten(selections, path="", condition=""):
    """Every selection as (kind, path, name, conditions)."""
    for kind, name, own, children in selections:
        conditions = condition + own
        label = {"on": f"<{name}>", "spread": f"...{name}"}.get(kind, name)
        here = f"{path} > {label}" if path else label
        yield kind, here, name, conditions
        yield from flatten(children, here, conditions)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    fragments, unread = [], 0
    with open(sys.argv[1], errors="replace") as file:
        for line in file:
            for match in re.finditer(r"\bfragment \w+ on \w+ ?[{@]", line):
                try:
                    fragments.append(Parser(line[match.start() :]).fragment())
                except (ValueError, IndexError):
                    unread += 1
    if not fragments:
        sys.exit("no GraphQL fragments found")
    if unread:
        print(f"{unread} GraphQL fragment(s) couldn't be read", file=sys.stderr)

    type_of = {name: on for name, on, _ in fragments}
    schema, locations, fields = set(), set(), set()
    for fragment, on, selections in fragments:
        inside_ad = " "  # the last ad found, whose own insides don't need listing
        if AD_NAME.search(on):
            schema.add(on)
        for kind, path, name, conditions in flatten(selections):
            if on in CARD_TYPES and not path.endswith("__typename"):
                fields.add(f"{on} {fragment}: {path}{conditions}")
            if kind == "field":
                names = name.split("=")
                for part in names:
                    if AD_NAME.search(part):
                        schema.add(part)
                is_ad = any(AD_NAME.search(part) for part in names)
            elif kind == "on":
                is_ad = bool(AD_NAME.search(name))
                if is_ad:
                    schema.add(name)
            else:
                is_ad = bool(AD_NAME.search(type_of.get(name, "")))
            if is_ad and not AD_NAME.search(on) and not path.startswith(inside_ad):
                locations.add(f"{fragment} on {on}: {path}{conditions}")
                inside_ad = path + " > "
    for title, lines in (("ad-schema", schema), ("ad-locations", locations), ("feed-fields", fields)):
        print(f"[{title}]")
        print("\n".join(sorted(lines)))


main()
