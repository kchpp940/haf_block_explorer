from __future__ import annotations

import sys
from pathlib import Path

import pytest

API_GEN_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = API_GEN_DIR.parent.parent
sys.path.insert(0, str(API_GEN_DIR))

from rewrite_rules_parser import (  # noqa: E402
    REWRITE_ORDER,
    RewriteRule,
    parse_rewrite_rules,
    rewrite_rules_to_conf,
)


REWRITE_CONF = PROJECT_ROOT / "endpoints" / "rewrite_rules.conf"
FIXTURE_CONF = API_GEN_DIR / "fixtures" / "rewrite_rules.conf"

EXPECTED_ENDPOINT_MARKERS = [
    "/operation-type-counts",
    "/input-type/{input-value}",
    "/last-synced-block",
    "/version",
    "/operation-type-statistics",
    "/transaction-statistics",
    "/proposals/{proposal-id}/votes/history",
    "/proposals/votes",
    "/proposals",
    "/block-search",
    "/total_wallet_addresses",
    "/accounts/{account-name}/operations/comments/{permlink}",
    "/accounts/{account-name}/comment-permlinks",
    "/accounts/{account-name}/proxy-power",
    "/accounts/{account-name}/authority",
    "/accounts/{account-name}",
    "/witnesses/{account-name}/votes/history",
    "/witnesses/{account-name}/voters/count",
    "/witnesses/{account-name}/voters",
    "/witnesses/{account-name}",
    "/witnesses",
]


def test_rewrite_conf_exists():
    assert REWRITE_CONF.exists(), f"Missing {REWRITE_CONF}"


def test_fixture_conf_exists():
    assert FIXTURE_CONF.exists(), f"Missing fixture {FIXTURE_CONF}"


def test_parse_all_rules():
    rules = parse_rewrite_rules(REWRITE_CONF)
    assert len(rules) >= 22, f"Expected at least 22 rules, got {len(rules)}"


def test_each_rule_has_pattern_replacement_and_comment():
    rules = parse_rewrite_rules(REWRITE_CONF)
    for rule in rules:
        assert rule.pattern, f"Rule has empty pattern"
        assert rule.replacement, f"Rule has empty replacement"
        assert rule.comment, f"Rule for pattern {rule.pattern} has no comment"


def test_rules_are_deterministically_ordered():
    rules_a = parse_rewrite_rules(REWRITE_CONF)
    rules_b = parse_rewrite_rules(REWRITE_CONF)
    patterns_a = [r.pattern for r in rules_a]
    patterns_b = [r.pattern for r in rules_b]
    assert patterns_a == patterns_b


def test_rules_order_matches_fixed_priority():
    rules = parse_rewrite_rules(REWRITE_CONF)
    orders = [r.order for r in rules]
    assert orders == sorted(orders), "Rules should be sorted by order ascending"


def test_specific_endpoint_rules_before_generic_catchall():
    rules = parse_rewrite_rules(REWRITE_CONF)
    patterns = [r.pattern for r in rules]
    catchall_idx = patterns.index("^/(.*)$")
    for idx, pattern in enumerate(patterns):
        if pattern == "^/(.*)$":
            continue
        assert idx < catchall_idx, (
            f"Specific rule {pattern} (idx={idx}) must appear before catch-all ^/(.*)$ (idx={catchall_idx})"
        )


def test_round_trip_parse_and_serialize_preserves_content():
    rules = parse_rewrite_rules(REWRITE_CONF)
    serialized = rewrite_rules_to_conf(rules)
    reparsed = parse_rewrite_rules(Path("/dev/null"))
    reparsed.clear()
    reparsed.extend(parse_rewrite_rules_from_text(serialized))
    orig_patterns = [r.pattern for r in rules]
    new_patterns = [r.pattern for r in reparsed]
    assert orig_patterns == new_patterns
    orig_comments = [r.comment for r in rules]
    new_comments = [r.comment for r in reparsed]
    assert orig_comments == new_comments


def parse_rewrite_rules_from_text(text: str) -> list[RewriteRule]:
    from rewrite_rules_parser import _rule_key
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


def test_fixture_conf_matches_source():
    from_source = parse_rewrite_rules(REWRITE_CONF)
    from_fixture = parse_rewrite_rules(FIXTURE_CONF)
    src_pairs = [(r.pattern, r.replacement, r.comment, r.order) for r in from_source]
    fix_pairs = [(r.pattern, r.replacement, r.comment, r.order) for r in from_fixture]
    assert src_pairs == fix_pairs, (
        "Rewrite rules fixture does not match source. "
        "Re-run `python scripts/api_generation/generate_and_validate.py export-fixtures`."
    )


def test_all_expected_endpoints_covered_by_rules():
    rules = parse_rewrite_rules(REWRITE_CONF)
    rule_comments_lower = [r.comment.lower() for r in rules]
    for marker in EXPECTED_ENDPOINT_MARKERS:
        marker_lower = marker.lower()
        matched = any(
            marker_lower in comment or
            marker_lower.replace("{account-name}", "") in comment or
            marker_lower.replace("{proposal-id}", "") in comment or
            marker_lower.replace("{input-value}", "") in comment or
            marker_lower.replace("{permlink}", "") in comment
            for comment in rule_comments_lower
        )
        assert matched, f"No rewrite rule comment mentions endpoint: {marker}"


def test_rewrite_order_is_defined_for_all_rule_markers():
    for rule in parse_rewrite_rules(REWRITE_CONF):
        if rule.comment == "endpoint for openapi spec itself":
            continue
        if rule.comment == "default endpoint for everything else":
            continue
        matches = sum(1 for marker in REWRITE_ORDER if marker in rule.comment)
        assert matches >= 1, f"Rule comment '{rule.comment}' does not match any marker in REWRITE_ORDER"
