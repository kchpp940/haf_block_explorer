from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import List


@dataclass
class RewriteRule:
    source_pattern: str
    target_rpc: str
    params: dict[str, str] = field(default_factory=dict)
    http_method: str = ""
    description: str = ""


_REWRITE_LINE_RE = re.compile(
    r"^rewrite\s+(?P<pattern>\S+)\s+(?P<target>\S+?)(?:\?(?P<query>[^ ]+))?\s+break;\s*$"
)

_ENDPOINT_COMMENT_RE = re.compile(
    r"^#\s+endpoint\s+for\s+(?P<method>\w+)\s+(?P<path>.+?)\s*$"
)


def _parse_query_string(query: str) -> dict[str, str]:
    params: dict[str, str] = {}
    if not query:
        return params
    for pair in query.split("&"):
        if "=" in pair:
            key, value = pair.split("=", 1)
            params[key] = value
    return params


def parse_rewrite_rules_content(content: str) -> List[RewriteRule]:
    lines = content.splitlines()
    rules: List[RewriteRule] = []

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        rewrite_match = _REWRITE_LINE_RE.match(line)
        if rewrite_match:
            source_pattern = rewrite_match.group("pattern")
            target = rewrite_match.group("target")
            query = rewrite_match.group("query") or ""
            params = _parse_query_string(query)

            http_method = ""
            description = ""

            if i + 1 < len(lines):
                next_line = lines[i + 1].strip()
                comment_match = _ENDPOINT_COMMENT_RE.match(next_line)
                if comment_match:
                    http_method = comment_match.group("method").lower()
                    description = comment_match.group("path")
                    i += 1

            rules.append(
                RewriteRule(
                    source_pattern=source_pattern,
                    target_rpc=target,
                    params=params,
                    http_method=http_method,
                    description=description,
                )
            )
        i += 1

    return rules


def parse_rewrite_rules(file_path: str | Path) -> List[RewriteRule]:
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")
    return parse_rewrite_rules_content(content)
