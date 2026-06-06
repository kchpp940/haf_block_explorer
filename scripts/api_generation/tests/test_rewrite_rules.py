from __future__ import annotations

from pathlib import Path

import pytest

from ..rewrite_rules_parser import parse_rewrite_rules, parse_rewrite_rules_content

FIXTURES_DIR = Path(__file__).parent.parent / "fixtures"
REWRITE_RULES_PATH = FIXTURES_DIR / "rewrite_rules.conf"


def test_parse_simple_rewrite() -> None:
    content = "rewrite ^/version /rpc/get_hafbe_version break;\n# endpoint for get /version\n"
    rules = parse_rewrite_rules_content(content)
    assert len(rules) == 1
    rule = rules[0]
    assert rule.source_pattern == "^/version"
    assert rule.target_rpc == "/rpc/get_hafbe_version"
    assert rule.http_method == "get"
    assert rule.params == {}
    assert rule.description == "/version"


def test_parse_rewrite_with_params() -> None:
    content = (
        "rewrite ^/accounts/([^/]+) /rpc/get_account?account-name=$1 break;\n"
        "# endpoint for get /accounts/{account-name}\n"
    )
    rules = parse_rewrite_rules_content(content)
    assert len(rules) == 1
    rule = rules[0]
    assert rule.source_pattern == "^/accounts/([^/]+)"
    assert rule.target_rpc == "/rpc/get_account"
    assert rule.http_method == "get"
    assert rule.params == {"account-name": "$1"}
    assert rule.description == "/accounts/{account-name}"


def test_parse_multiple_rules() -> None:
    rules = parse_rewrite_rules(REWRITE_RULES_PATH)
    assert len(rules) == 23


def test_parse_invalid_content() -> None:
    rules = parse_rewrite_rules_content("")
    assert rules == []


def test_parse_rewrite_with_multiple_params() -> None:
    content = (
        "rewrite ^/accounts/([^/]+)/operations/comments/([^/]+) "
        "/rpc/get_comment_operations?account-name=$1&permlink=$2 break;\n"
        "# endpoint for get /accounts/{account-name}/operations/comments/{permlink}\n"
    )
    rules = parse_rewrite_rules_content(content)
    assert len(rules) == 1
    rule = rules[0]
    assert rule.params == {"account-name": "$1", "permlink": "$2"}


def test_parse_rewrite_skips_rules_without_endpoint_comment() -> None:
    content = "rewrite ^/$ / break;\n"
    rules = parse_rewrite_rules_content(content)
    assert len(rules) == 1
    rule = rules[0]
    assert rule.http_method == ""
    assert rule.description == ""
