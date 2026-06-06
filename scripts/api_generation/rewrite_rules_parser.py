from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass
class RewriteRule:
    pattern: str
    replacement: str
    comment: str
    order: int


REWRITE_ORDER: list[str] = [
    "/operation-type-counts",
    "/input-type/",
    "/last-synced-block",
    "/version",
    "/operation-type-statistics",
    "/transaction-statistics",
    "/proposals/",
    "/proposals/votes",
    "/proposals",
    "/block-search",
    "/total_wallet_addresses",
    "/accounts/",
    "/witnesses/",
    "/witnesses",
    "^/$",
    "^/(.*)$",
]


def _rule_key(comment: str) -> int:
    for idx, marker in enumerate(REWRITE_ORDER):
        if marker in comment:
            return idx
    return len(REWRITE_ORDER)


def parse_rewrite_rules(conf_path: Path) -> list[RewriteRule]:
    text = conf_path.read_text(encoding="utf-8")
    rules: list[RewriteRule] = []
    pending_pattern: str | None = None
    pending_replacement: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("rewrite "):
            if pending_pattern is not None:
                rules.append(
                    RewriteRule(
                        pattern=pending_pattern,
                        replacement=pending_replacement or "",
                        comment="",
                        order=_rule_key(""),
                    )
                )
            inner = line[len("rewrite "):]
            if inner.endswith(";"):
                inner = inner[:-1]
            parts = inner.split()
            if len(parts) >= 2:
                pending_pattern = parts[0]
                pending_replacement = parts[1]
            else:
                pending_pattern = None
                pending_replacement = None
            continue
        if line.startswith("#") and pending_pattern is not None:
            comment = line.lstrip("#").strip()
            rules.append(
                RewriteRule(
                    pattern=pending_pattern,
                    replacement=pending_replacement or "",
                    comment=comment,
                    order=_rule_key(comment),
                )
            )
            pending_pattern = None
            pending_replacement = None
            continue
    if pending_pattern is not None:
        rules.append(
            RewriteRule(
                pattern=pending_pattern,
                replacement=pending_replacement or "",
                comment="",
                order=_rule_key(""),
            )
        )
    rules.sort(key=lambda r: (r.order, r.pattern))
    return rules


def rewrite_rules_to_conf(rules: list[RewriteRule]) -> str:
    lines: list[str] = []
    for rule in rules:
        lines.append(f"rewrite {rule.pattern} {rule.replacement} break;")
        if rule.comment:
            lines.append(f"# {rule.comment}")
        lines.append("")
    return "\n".join(lines)
