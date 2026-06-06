#!/usr/bin/env python3
"""
HAF Block Explorer — Unified Test Bootstrap
============================================

Consolidates mock-data installation, HAF state rewinding, regression-test
schema setup, expected-data loading, verification and diagnostics into a
single entry point so that local developers, regression/run_test.sh, the
docker-compose mock pipeline and the GitLab CI mock jobs all drive the
same codepath.

Subcommands
-----------
  check               Pre-flight diagnostics (schemas, tables, blocks, data)
  mock-install        Install mock SQL helpers, insert blocks/ops, rewind HAF
  mock-verify         Refresh caches and run mock verification with diagnostics
  mock-full           End-to-end mock pipeline: install → process → verify
  regression-install  Install regression schema (hafbe_test) and load expected dumps
  regression-run      Run account/witness comparison with detailed failure report
  regression-full     End-to-end regression: install → run

Exit codes
----------
  0  everything passed
  1  one or more checks failed (details on stderr)
  2  invalid arguments / environment error
  3  database connectivity error
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")


class _TeeWriter:
    """Writes simultaneously to the original ``sys.stderr`` and a log file.

    ANSI SGR escape sequences (colours, bold, reset) are stripped before
    writing to the log file so that the on-disk log is human-readable in
    plain-text viewers.  Flushes both streams after every write so that
    diagnostic information written immediately before a crash still ends up
    on disk.
    """

    def __init__(self, original_stream, log_file):
        self._orig = original_stream
        self._file = log_file

    def write(self, data: str) -> int:
        written = self._orig.write(data)
        self._file.write(_ANSI_RE.sub("", data))
        self._file.flush()
        return written

    def flush(self) -> None:
        self._orig.flush()
        self._file.flush()

    def isatty(self) -> bool:
        return self._orig.isatty()


def _install_log_file(log_path: Optional[str]) -> Optional[_TeeWriter]:
    """Open ``log_path`` and replace ``sys.stderr`` with a tee writer.

    Returns the installed tee writer (so callers can restore the original
    stream later) or ``None`` if no log file was requested.
    """
    if not log_path:
        return None
    try:
        Path(log_path).parent.mkdir(parents=True, exist_ok=True)
        fh = open(log_path, "w", encoding="utf-8")
    except OSError as exc:
        sys.stderr.write(
            f"ERROR: cannot open log file {log_path}: {exc}\n"
        )
        sys.exit(2)
    tee = _TeeWriter(sys.stderr, fh)
    sys.stderr = tee
    return tee


# psycopg2 is imported at module load but import failures are deferred until
# the first database connection attempt, so ``--help`` and friend work even
# without the driver installed.
_PSYCOPG2_IMPORT_ERROR: Optional[ImportError] = None
try:
    import psycopg2
    from psycopg2.extras import RealDictCursor
    _PSYCOPG2_ERROR = psycopg2.Error
    _PSYCOPG2_OPERATIONAL_ERROR = psycopg2.OperationalError
except ImportError as _exc:
    psycopg2 = None  # type: ignore
    RealDictCursor = None  # type: ignore
    _PSYCOPG2_IMPORT_ERROR = _exc
    _PSYCOPG2_ERROR = Exception
    _PSYCOPG2_OPERATIONAL_ERROR = OSError


def _ensure_psycopg2() -> None:
    if _PSYCOPG2_IMPORT_ERROR is not None:
        sys.stderr.write(
            "ERROR: psycopg2 is required. Install with: pip install psycopg2-binary\n"
            f"  ({_PSYCOPG2_IMPORT_ERROR})\n"
        )
        sys.exit(2)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
HAFBE_ROOT = SCRIPT_DIR.parent
MOCKS_DIR = HAFBE_ROOT / "tests" / "mocks"
MOCKS_SQL_DIR = MOCKS_DIR / "sql"
MOCKS_FIXTURES_DIR = MOCKS_DIR / "fixtures"
REGRESSION_DIR = HAFBE_ROOT / "tests" / "regression"
REGRESSION_SQL_DIR = REGRESSION_DIR / "sql"


# ---------------------------------------------------------------------------
# Colour / formatting helpers
# ---------------------------------------------------------------------------

def _supports_color() -> bool:
    return sys.stderr.isatty() and os.environ.get("NO_COLOR") is None


C_RED = "\033[31m" if _supports_color() else ""
C_GREEN = "\033[32m" if _supports_color() else ""
C_YELLOW = "\033[33m" if _supports_color() else ""
C_BOLD = "\033[1m" if _supports_color() else ""
C_RESET = "\033[0m" if _supports_color() else ""

STATUS_COLORS = {
    "PASS": C_GREEN,
    "FAIL": C_RED,
    "IN_PROGRESS": C_YELLOW,
}


def _print_header(title: str) -> None:
    bar = "=" * 62
    sys.stderr.write(f"\n{C_BOLD}{bar}{C_RESET}\n")
    sys.stderr.write(f"{C_BOLD}  {title}{C_RESET}\n")
    sys.stderr.write(f"{C_BOLD}{bar}{C_RESET}\n\n")


def _print_status(label: str, status: str, detail: str = "") -> None:
    color = STATUS_COLORS.get(status, "")
    sys.stderr.write(f"  [{color}{status:12s}{C_RESET}] {label}")
    if detail:
        sys.stderr.write(f"\n             {C_YELLOW}{detail}{C_RESET}")
    sys.stderr.write("\n")


def _print_table(headers: list[str], rows: Iterable[list[str]]) -> None:
    rows = list(rows)
    if not rows:
        return
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    fmt = "  " + "  ".join(f"{{:<{w}}}" for w in widths)
    sys.stderr.write(fmt.format(*headers) + "\n")
    sys.stderr.write("  " + "  ".join("-" * w for w in widths) + "\n")
    for row in rows:
        cells = [str(c) for c in row]
        if len(cells) >= len(headers) and cells[-1] in STATUS_COLORS:
            color = STATUS_COLORS[cells[-1]]
            cells[-1] = f"{color}{cells[-1]}{C_RESET}"
        sys.stderr.write(fmt.format(*cells) + "\n")


def _print_error_section(title: str, items: list[str]) -> None:
    if not items:
        return
    sys.stderr.write(f"\n{C_RED}{C_BOLD}  ✗ {title}{C_RESET}\n")
    for item in items:
        sys.stderr.write(f"    - {item}\n")


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

@dataclass
class DBConfig:
    host: str
    port: int
    user: str
    database: str
    url: Optional[str] = None

    @property
    def access(self) -> str:
        if self.url:
            return self.url
        return f"postgresql://{self.user}@{self.host}:{self.port}/{self.database}"

    def connect(self):
        _ensure_psycopg2()
        return psycopg2.connect(self.access)


def add_db_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--host", default=os.environ.get("POSTGRES_HOST", "localhost"),
                        help="PostgreSQL hostname (default: localhost or $POSTGRES_HOST)")
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("POSTGRES_PORT", "5432")),
                        help="PostgreSQL port (default: 5432 or $POSTGRES_PORT)")
    parser.add_argument("--user", default=os.environ.get("POSTGRES_USER", "haf_admin"),
                        help="PostgreSQL user (default: haf_admin or $POSTGRES_USER)")
    parser.add_argument("--database", default=os.environ.get("POSTGRES_DB", "haf_block_log"),
                        help="PostgreSQL database (default: haf_block_log)")
    parser.add_argument("--url", default=os.environ.get("POSTGRES_URL", ""),
                        help="Full PostgreSQL URL (overrides --host/--port/--user/--database)")
    parser.add_argument("--skip-if-no-db", action="store_true",
                        help="Exit 0 cleanly if database is unreachable (for local dev / optional CI)")
    parser.add_argument("--log-file", default=os.environ.get("TEST_BOOTSTRAP_LOG", ""),
                        help="Append a copy of all diagnostic output to this file "
                             "(ANSI colours stripped). Also accepts $TEST_BOOTSTRAP_LOG.")


def _preflight_db(db: DBConfig, skip_if_no_db: bool = False,
                  connect_timeout_sec: int = 5) -> None:
    """Verify database connectivity before running any subcommand.

    On failure either exits 0 (``--skip-if-no-db``) or exits 3 with an
    actionable diagnostic message suggesting what the operator should do next
    (start Docker, verify HAF service is up, check ports, etc.).
    """
    import socket

    # First try a TCP-level connect so we can distinguish "port not open"
    # from "PostgreSQL rejects auth" — different advice for each.
    try:
        with socket.create_connection((db.host, db.port), timeout=connect_timeout_sec):
            pass
    except OSError as exc:
        msg = (
            f"Cannot reach PostgreSQL at {db.host}:{db.port} "
            f"(socket error: {exc.__class__.__name__}: {exc})"
        )
        if skip_if_no_db:
            sys.stderr.write(f"{C_YELLOW}{msg}{C_RESET}\n")
            sys.stderr.write(
                f"{C_YELLOW}--skip-if-no-db set — exiting 0 without running tests.{C_RESET}\n"
            )
            sys.exit(0)
        sys.stderr.write(f"\n{C_RED}{C_BOLD}ERROR: {msg}{C_RESET}\n")
        in_ci = os.environ.get("CI", "") == "true"
        in_docker = os.path.exists("/.dockerenv") or os.environ.get("DOCKER_HOST", "")
        sys.stderr.write(f"\n{C_BOLD}  Suggested next steps:{C_RESET}\n")
        if in_ci:
            sys.stderr.write(
                f"    - Is the Docker-in-Docker 'docker' service healthy?\n"
                f"    - Did docker-compose up finish starting the HAF container?\n"
                f"    - Check container logs: docker compose logs haf\n"
            )
        elif in_docker:
            sys.stderr.write(
                f"    - Is the HAF / 'haf' container reachable on this Docker network?\n"
                f"    - Check HAF health: docker inspect --format='{{{{.State.Health.Status}}}}' <container>\n"
            )
        else:
            sys.stderr.write(
                f"    - Is Docker running?  (docker ps)\n"
                f"    - Start the HAF environment:  cd docker && docker compose up -d\n"
                f"    - Verify the HAF service is healthy:  docker compose ps\n"
                f"    - Is PostgreSQL listening on {db.port}?  (lsof -i :{db.port})\n"
            )
        sys.stderr.write(
            f"    - Connection string used:  postgresql://{db.user}@{db.host}:{db.port}/{db.database}\n\n"
        )
        sys.exit(3)

    # TCP works — now try a real PostgreSQL handshake so we catch auth /
    # wrong-database errors with their own advice.
    try:
        conn = db.connect()
        try:
            cur = conn.cursor()
            cur.execute("SELECT 1")
        finally:
            conn.close()
    except _PSYCOPG2_OPERATIONAL_ERROR as exc:
        msg = f"PostgreSQL at {db.host}:{db.port} responded but is not usable: {exc}"
        if skip_if_no_db:
            sys.stderr.write(f"{C_YELLOW}{msg}{C_RESET}\n")
            sys.stderr.write(
                f"{C_YELLOW}--skip-if-no-db set — exiting 0 without running tests.{C_RESET}\n"
            )
            sys.exit(0)
        sys.stderr.write(f"\n{C_RED}{C_BOLD}ERROR: {msg}{C_RESET}\n")
        sys.stderr.write(
            f"\n{C_BOLD}  Suggested next steps:{C_RESET}\n"
            f"    - Is the database '{db.database}' created?\n"
            f"    - Does user '{db.user}' have access?\n"
            f"    - Connection string used:  postgresql://{db.user}@{db.host}:{db.port}/{db.database}\n\n"
        )
        sys.exit(3)
    except _PSYCOPG2_ERROR as exc:
        if skip_if_no_db:
            sys.stderr.write(f"{C_YELLOW}Database error: {exc}{C_RESET}\n")
            sys.stderr.write(
                f"{C_YELLOW}--skip-if-no-db set — exiting 0 without running tests.{C_RESET}\n"
            )
            sys.exit(0)
        raise


def db_from_args(args: argparse.Namespace) -> DBConfig:
    return DBConfig(
        host=args.host,
        port=args.port,
        user=args.user,
        database=args.database,
        url=args.url or None,
    )


def run_sql_file(db: DBConfig, sql_path: Path, set_search_path: Optional[str] = None) -> None:
    if not sql_path.exists():
        raise FileNotFoundError(f"SQL file not found: {sql_path}")
    conn = db.connect()
    try:
        conn.autocommit = True
        cur = conn.cursor()
        if set_search_path:
            cur.execute(f"SET search_path TO {set_search_path}")
        cur.execute(sql_path.read_text())
    finally:
        conn.close()


DIAGNOSTICS_SQL = MOCKS_SQL_DIR / "diagnostics.sql"


def _ensure_diagnostics_sql(db: DBConfig) -> None:
    """Idempotently install the hafbe_backend.diagnose_* helper functions.

    Safe to call multiple times — diagnostics.sql uses ``CREATE OR REPLACE
    FUNCTION``.  Raises if the HAFBE backend schema is not present.
    """
    run_sql_file(db, DIAGNOSTICS_SQL)


def run_sql(db: DBConfig, sql: str, set_search_path: Optional[str] = None,
            use_dict_cursor: bool = False):
    conn = db.connect()
    try:
        conn.autocommit = True
        cur_factory = RealDictCursor if use_dict_cursor else None
        cur = conn.cursor(cursor_factory=cur_factory)
        if set_search_path:
            cur.execute(f"SET search_path TO {set_search_path}")
        cur.execute(sql)
        if cur.description:
            return cur.fetchall()
        return []
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Subcommand: check  (pre-flight diagnostics)
# ---------------------------------------------------------------------------

def cmd_check(args: argparse.Namespace) -> int:
    db = db_from_args(args)
    _preflight_db(db, getattr(args, "skip_if_no_db", False))
    overall_ok = True
    failures: dict[str, list[str]] = {
        "Missing tables / schemas": [],
        "Missing mock block ranges": [],
        "HAF context state issues": [],
        "Regression schema issues": [],
        "Expected data not loaded": [],
    }

    _print_header("Pre-flight diagnostics")
    sys.stderr.write(f"  Host:     {db.host}:{db.port}\n")
    sys.stderr.write(f"  User:     {db.user}\n")
    sys.stderr.write(f"  Database: {db.database}\n\n")

    # Install / refresh diagnostic functions (idempotent) so that the
    # diagnose_* queries below always have something to call.
    try:
        _ensure_diagnostics_sql(db)
    except (_PSYCOPG2_ERROR, FileNotFoundError) as exc:
        msg = f"cannot install diagnostic SQL: {exc}"
        _print_status("diagnostics setup", "FAIL", msg)
        for key in failures:
            failures[key].append(msg)
        sys.stderr.write(f"{C_RED}{C_BOLD}  ✗ Diagnostics unavailable — HAFBE not installed?{C_RESET}\n\n")
        return 3

    # 1. Core schema / tables
    _print_header("1. Core HAFBE schema & tables")
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_missing_tables()")
        table_rows = []
        for r in rows:
            schema, obj_type, obj_name, status = r
            table_rows.append([schema, obj_type, obj_name, status])
            if status == "FAIL":
                overall_ok = False
                failures["Missing tables / schemas"].append(
                    f"{schema}.{obj_name} ({obj_type})"
                )
        _print_table(["schema", "type", "name", "status"], table_rows)
    except _PSYCOPG2_ERROR as exc:
        overall_ok = False
        msg = f"cannot query diagnose_missing_tables(): {exc}"
        _print_status("schema diagnostics", "FAIL", msg)
        failures["Missing tables / schemas"].append(msg)

    # 2. Mock block range
    _print_header("2. Mock block range completeness")
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_mock_block_range()")
        for check_name, expected, actual, status, detail in rows:
            _print_status(check_name, status,
                          f"expected={expected}  actual={actual}  {detail}")
            if status == "FAIL":
                overall_ok = False
                failures["Missing mock block ranges"].append(
                    f"{check_name}: expected {expected}, got {actual} — {detail}"
                )
    except _PSYCOPG2_ERROR as exc:
        msg = f"cannot query diagnose_mock_block_range(): {exc}"
        _print_status("block range diagnostics", "FAIL", msg)
        overall_ok = False
        failures["Missing mock block ranges"].append(msg)

    # 3. HAF context state
    _print_header("3. HAF context state")
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_context_state()")
        table_rows = []
        for ctx, cur, irrev, consistent, status, detail in rows:
            table_rows.append([ctx, str(cur), str(irrev), str(consistent), status])
            _print_status(f"context {ctx}", status, detail)
            if status == "FAIL":
                overall_ok = False
                failures["HAF context state issues"].append(
                    f"{ctx}: {detail}"
                )
        _print_table(
            ["context", "current", "irreversible", "consistent", "status"],
            table_rows,
        )
    except _PSYCOPG2_ERROR as exc:
        msg = f"cannot query diagnose_context_state(): {exc}"
        _print_status("context diagnostics", "FAIL", msg)
        overall_ok = False
        failures["HAF context state issues"].append(msg)

    # 4. Regression schema
    _print_header("4. Regression test schema (hafbe_test)")
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_regression_schema()")
        table_rows = []
        for schema, obj_type, obj_name, status in rows:
            table_rows.append([schema, obj_type, obj_name, status])
            if status == "FAIL":
                overall_ok = False
                failures["Regression schema issues"].append(
                    f"{schema}.{obj_name} ({obj_type})"
                )
        _print_table(["schema", "type", "name", "status"], table_rows)
    except _PSYCOPG2_ERROR:
        _print_status("regression schema not installed", "IN_PROGRESS",
                      "run 'regression-install' to set up hafbe_test")

    # 5. Expected data load
    _print_header("5. Expected data load")
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_expected_data_load()")
        for table_name, row_count, status, detail in rows:
            _print_status(f"{table_name}", status, f"{row_count} rows — {detail}")
            if status == "FAIL":
                overall_ok = False
                failures["Expected data not loaded"].append(f"{table_name}: {detail}")
    except _PSYCOPG2_ERROR:
        _print_status("expected-data check skipped", "IN_PROGRESS",
                      "hafbe_test schema not yet installed")

    # Final summary
    _print_header("Summary")
    if overall_ok:
        sys.stderr.write(f"{C_GREEN}{C_BOLD}  ✓ All pre-flight checks passed{C_RESET}\n\n")
        return 0

    sys.stderr.write(f"{C_RED}{C_BOLD}  ✗ Some pre-flight checks failed{C_RESET}\n")
    for section, items in failures.items():
        _print_error_section(section, items)
    sys.stderr.write("\n")
    return 1


# ---------------------------------------------------------------------------
# Subcommand: mock-install
# ---------------------------------------------------------------------------

def _get_expected_mock_block_range() -> tuple[int, int]:
    """Read blocks fixture JSON and return (min, max) expected block numbers."""
    data = json.loads((MOCKS_FIXTURES_DIR / "blocks" / "data.json").read_text())
    block_nums = sorted(b["block_num"] for b in data["blocks"])
    return block_nums[0], block_nums[-1]


def cmd_mock_install(args: argparse.Namespace) -> int:
    db = db_from_args(args)
    _preflight_db(db, getattr(args, "skip_if_no_db", False))
    _print_header("Mock data installation")
    sys.stderr.write(f"  Host: {db.host}:{db.port}  User: {db.user}\n\n")

    # Step 1: Install SQL helpers (types + insert functions + state updaters + diagnostics)
    sys.stderr.write("Step 1/4: Installing mock SQL helpers...\n")
    for sql_name in ("types.sql", "insert_blocks.sql", "insert_operations.sql",
                     "update_haf_state.sql", "diagnostics.sql"):
        sql_path = MOCKS_SQL_DIR / sql_name
        sys.stderr.write(f"  - installing {sql_name}\n")
        try:
            run_sql_file(db, sql_path)
        except (_PSYCOPG2_ERROR, FileNotFoundError) as exc:
            sys.stderr.write(f"{C_RED}    ERROR: {exc}{C_RESET}\n")
            return 3
    sys.stderr.write("  done.\n\n")

    # Step 2: Insert mock block headers
    sys.stderr.write("Step 2/4: Inserting mock block headers...\n")
    blocks_data = (MOCKS_FIXTURES_DIR / "blocks" / "data.json").read_text()
    try:
        conn = db.connect()
        try:
            conn.autocommit = True
            cur = conn.cursor()
            cur.execute("SELECT hafbe_backend.insert_mock_blocks(%s)", (blocks_data,))
        finally:
            conn.close()
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_RED}  ERROR inserting mock blocks: {exc}{C_RESET}\n")
        return 3
    sys.stderr.write("  done.\n\n")

    # Step 3: Insert mock operations
    sys.stderr.write("Step 3/4: Inserting mock operations...\n")
    ops_data = (MOCKS_FIXTURES_DIR / "proposals" / "data.json").read_text()
    try:
        conn = db.connect()
        try:
            conn.autocommit = True
            cur = conn.cursor()
            cur.execute("SELECT hafbe_backend.insert_mock_operations(%s)", (ops_data,))
        finally:
            conn.close()
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_RED}  ERROR inserting mock operations: {exc}{C_RESET}\n")
        return 3
    sys.stderr.write("  done.\n\n")

    # Step 4: Rewind HAF contexts
    sys.stderr.write("Step 4/4: Rewinding hafbe_app + hafbe_bal contexts...\n")
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.update_irreversible_block()")
        if rows:
            start_block, end_block = rows[0]
            sys.stderr.write(f"  Block range: {start_block}..{end_block}\n")
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_RED}  ERROR rewinding contexts: {exc}{C_RESET}\n")
        return 3

    # Diagnose the result
    sys.stderr.write("\n")
    _print_header("Post-install diagnostics")
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_mock_block_range()")
        for check_name, expected, actual, status, detail in rows:
            _print_status(check_name, status,
                          f"expected={expected}  actual={actual}  {detail}")
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_context_state()")
        for ctx, cur, irrev, consistent, status, detail in rows:
            _print_status(f"context {ctx}", status, detail)
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_YELLOW}  diagnostics unavailable: {exc}{C_RESET}\n")

    min_b, max_b = _get_expected_mock_block_range()
    _print_header("Mock installation complete")
    sys.stderr.write(f"{C_GREEN}  ✓ Mock fixtures loaded{C_RESET}\n")
    sys.stderr.write(f"  Block range: {min_b}..{max_b}\n")
    sys.stderr.write("\nNext steps:\n")
    sys.stderr.write(f"  1. Process the mock range:\n")
    sys.stderr.write(f"       ./scripts/process_blocks.sh --stop-at-block={max_b}\n")
    sys.stderr.write(f"  2. Verify expected state:\n")
    sys.stderr.write(f"       ./scripts/test_bootstrap.py mock-verify\n")
    sys.stderr.write(f"     OR run the full pipeline:\n")
    sys.stderr.write(f"       ./scripts/test_bootstrap.py mock-full\n\n")
    return 0


# ---------------------------------------------------------------------------
# Subcommand: mock-verify
# ---------------------------------------------------------------------------

def cmd_mock_verify(args: argparse.Namespace) -> int:
    db = db_from_args(args)
    _preflight_db(db, getattr(args, "skip_if_no_db", False))
    btracker_schema = os.environ.get("BTRACKER_SCHEMA", "hafbe_bal")
    _print_header("Mock data verification")
    sys.stderr.write(f"  Host: {db.host}:{db.port}  User: {db.user}\n\n")

    # Install / refresh diagnostic functions first
    try:
        _ensure_diagnostics_sql(db)
    except (_PSYCOPG2_ERROR, FileNotFoundError) as exc:
        sys.stderr.write(f"{C_YELLOW}  diagnostics install skipped: {exc}{C_RESET}\n")

    # Step 1: Pre-verify diagnostics (fail fast with structured output)
    sys.stderr.write("Step 1/3: Running pre-verify diagnostics...\n")
    any_fail = False
    missing_tables: list[str] = []
    missing_blocks: list[str] = []
    mismatched_endpoints: list[str] = []

    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_missing_tables()")
        for schema, obj_type, obj_name, status in rows:
            if status == "FAIL":
                any_fail = True
                missing_tables.append(f"{schema}.{obj_name} ({obj_type})")
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_YELLOW}  schema diagnostics skipped: {exc}{C_RESET}\n")

    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_mock_block_range()")
        for check_name, expected, actual, status, detail in rows:
            _print_status(check_name, status,
                          f"expected={expected}  actual={actual}  {detail}")
            if status == "FAIL":
                any_fail = True
                missing_blocks.append(
                    f"{check_name}: expected {expected}, got {actual} — {detail}"
                )
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_YELLOW}  block-range diagnostics skipped: {exc}{C_RESET}\n")

    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_context_state()")
        for ctx, cur, irrev, consistent, status, detail in rows:
            _print_status(f"context {ctx}", status, detail)
            if status == "FAIL":
                any_fail = True
                missing_blocks.append(f"context {ctx}: {detail}")
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_YELLOW}  context diagnostics skipped: {exc}{C_RESET}\n")

    if any_fail:
        _print_header("Pre-verify FAILED — aborting before verify.sql")
        _print_error_section("Missing tables / schemas", missing_tables)
        _print_error_section("Missing block ranges / context issues", missing_blocks)
        sys.stderr.write(
            f"\n{C_YELLOW}  Run './scripts/test_bootstrap.py check' for the full report.{C_RESET}\n\n"
        )
        return 1

    # Step 2: Refresh caches (mirrors scripts/verify_mock_data.sh)
    sys.stderr.write("\nStep 2/3: Refreshing vote caches (witness first, then proposal)...\n")
    try:
        run_sql(db, "SELECT hafbe_app.process_witness_votes_cache()",
                set_search_path=f"{btracker_schema},public")
        run_sql(db, """
            INSERT INTO hafbe_app.account_vest_stats_cache (account_id, vests, account_vests, proxied_vests)
            SELECT av.id, 5000000, 5000000, 0
            FROM hive.accounts_view av
            WHERE av.name = 'initminer'
            ON CONFLICT (account_id) DO UPDATE
              SET vests         = 5000000,
                  account_vests = 5000000,
                  proxied_vests = 0;
        """)
        run_sql(db, "SELECT hafbe_app.process_proposal_vote_stats_cache()",
                set_search_path=f"{btracker_schema},public")
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_RED}  ERROR refreshing caches: {exc}{C_RESET}\n")
        return 3
    sys.stderr.write("  done.\n")

    # Step 3: Run verify.sql and capture failures
    sys.stderr.write("\nStep 3/3: Running verify.sql assertions...\n")
    verify_path = MOCKS_SQL_DIR / "verify.sql"

    conn = db.connect()
    try:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute(f"SET search_path TO {btracker_schema},public")
        with open(verify_path) as f:
            sql_text = f.read()
        cur.execute(sql_text)
        if cur.description:
            results = cur.fetchall()
            for row in results:
                sys.stderr.write("  " + " | ".join(str(c) for c in row) + "\n")
    except _PSYCOPG2_ERROR as exc:
        err_msg = str(exc)
        sys.stderr.write(f"\n{C_RED}{C_BOLD}  verify.sql FAILED{C_RESET}\n")
        sys.stderr.write(f"{C_RED}  {err_msg}{C_RESET}\n\n")

        # _hafbe_mock_checks is a TEMP VIEW — it only exists within THIS
        # connection session.  We MUST reuse `conn` (not open a new one),
        # otherwise `SELECT * FROM _hafbe_mock_checks` fails with "relation
        # does not exist".  Roll back any aborted transaction state first so
        # we can re-query on the same session.
        try:
            conn.rollback()
        except _PSYCOPG2_ERROR:
            pass
        try:
            diag_cur = conn.cursor()
            diag_cur.execute(f"SET search_path TO {btracker_schema},public")
            diag_cur.execute("""
                SELECT name, expected, actual, result FROM _hafbe_mock_checks
                WHERE result = 'FAIL'
                ORDER BY name
            """)
            failed = diag_cur.fetchall()
            if failed:
                mismatched_endpoints = [
                    f"{name}: expected={expected}, actual={actual or '<null>'}"
                    for name, expected, actual, _ in failed
                ]
        except _PSYCOPG2_ERROR as diag_exc:
            sys.stderr.write(
                f"{C_YELLOW}  (could not read _hafbe_mock_checks: {diag_exc}){C_RESET}\n"
            )
        finally:
            try:
                diag_cur.close()
            except Exception:
                pass

        _print_error_section("Mismatched endpoints / assertions", mismatched_endpoints)
        sys.stderr.write("\n")
        return 1
    finally:
        conn.close()

    _print_header("Mock verification complete")
    sys.stderr.write(f"{C_GREEN}{C_BOLD}  ✓ All mock assertions passed{C_RESET}\n\n")
    return 0


# ---------------------------------------------------------------------------
# Subcommand: mock-full
# ---------------------------------------------------------------------------

def _wait_for_indexes(db: DBConfig, timeout_minutes: int = 60,
                      poll_interval_sec: int = 20) -> None:
    """Poll ``hive.check_if_registered_indexes_created()`` until it returns true.

    Mirrors the same wait used by ``wait-for-haf-be-startup.sh``.  Exits 3 on
    timeout so CI can tell apart "index creation slow" from "verification
    failed".
    """
    start_time = time.time()
    end_time = start_time + timeout_minutes * 60
    iteration = 0
    while True:
        rows = run_sql(db,
            "SELECT hive.check_if_registered_indexes_created('hafbe_app')::INT")
        if rows and rows[0][0] == 1:
            return
        if time.time() >= end_time:
            sys.stderr.write(f"{C_RED}{C_BOLD}  Timeout waiting for registered "
                             f"indexes ({timeout_minutes} min){C_RESET}\n")
            sys.stderr.write("  Diagnostics:\n")
            ctx = run_sql(db,
                "SELECT name, current_block_num, irreversible_block "
                "FROM hafd.contexts WHERE name IN ('hafbe_app', 'hafbe_bal')")
            for name, blk, irb in ctx:
                sys.stderr.write(f"    context {name}: block={blk} irb={irb}\n")
            sys.exit(3)
        iteration += 1
        if iteration % 3 == 0:
            elapsed = int((time.time() - start_time) / 60)
            sys.stderr.write(f"  Waiting for registered indexes... ({elapsed}m elapsed)\n")
        else:
            sys.stderr.write("  Waiting for registered indexes...\n")
        time.sleep(poll_interval_sec)


def cmd_mock_full(args: argparse.Namespace) -> int:
    db = db_from_args(args)
    _preflight_db(db, getattr(args, "skip_if_no_db", False))

    rc = cmd_mock_install(args)
    if rc != 0:
        return rc

    # Step 2: Run process_blocks.sh (calls hafbe_app.main via psql)
    min_b, max_b = _get_expected_mock_block_range()
    _print_header(f"Processing mock blocks {min_b}..{max_b}")
    process_script = SCRIPT_DIR / "process_blocks.sh"
    cmd = [
        str(process_script),
        f"--host={db.host}",
        f"--port={db.port}",
        f"--user={db.user}",
        f"--stop-at-block={max_b}",
        "--log-file=STDOUT",
    ]
    sys.stderr.write(f"  $ {' '.join(shlex.quote(c) for c in cmd)}\n\n")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        sys.stderr.write(
            f"\n{C_RED}{C_BOLD}  process_blocks.sh failed with exit {result.returncode}{C_RESET}\n\n"
        )
        return result.returncode

    # Step 3: Create HAFBE + HAF indexes (mirrors wait-for-haf-be-startup.sh)
    _print_header("Creating HAFBE application indexes")
    try:
        run_sql(db, "SELECT hafbe_app.create_hafbe_indexes()")
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_RED}{C_BOLD}  ERROR creating hafbe indexes: {exc}{C_RESET}\n")
        return 3
    _print_status("hafbe_app indexes", "PASS", "created")

    _print_header("Restoring registered HAF table indexes")
    try:
        run_sql(db, "SELECT hive.app_restore_indexes('hafbe_app')")
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_RED}{C_BOLD}  ERROR restoring HAF indexes: {exc}{C_RESET}\n")
        return 3
    _print_status("HAF registered indexes", "IN_PROGRESS", "restored, waiting for build")
    _wait_for_indexes(db)
    _print_status("HAF registered indexes", "PASS", "all built")

    # Step 4: CHECKPOINT (prevents overloaded checkpointer on shutdown)
    _print_header("Flushing WAL (CHECKPOINT)")
    try:
        run_sql(db, "CHECKPOINT")
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_YELLOW}  WARNING: CHECKPOINT failed: {exc}{C_RESET}\n")
    else:
        _print_status("CHECKPOINT", "PASS", "complete")

    # Step 5: End-to-end verification
    return cmd_mock_verify(args)


# ---------------------------------------------------------------------------
# Subcommand: regression-install
# ---------------------------------------------------------------------------

def _gunzip_if_needed(gz_path: Path) -> Path:
    """Decompress ``<name>.gz`` to a temp directory and return the plain path.

    The source directory may be read-only (e.g. a Docker :ro volume mount), so
    we always extract under the system temp dir keyed by the source's
    modification time — no stale files, no write-permission issues.
    """
    if not gz_path.exists():
        raise FileNotFoundError(f"gz fixture not found: {gz_path}")

    cache_key = f"{gz_path.stem}-{gz_path.stat().st_mtime_ns}"
    tmp_dir = Path(tempfile.gettempdir()) / "hafbe_test_bootstrap"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    plain = tmp_dir / gz_path.stem

    if not plain.exists():
        sys.stderr.write(f"    extracting {gz_path.name} → {plain}\n")
        with gzip.open(gz_path, "rb") as src, open(plain, "wb") as dst:
            dst.write(src.read())
    return plain


def cmd_regression_install(args: argparse.Namespace) -> int:
    db = db_from_args(args)
    _preflight_db(db, getattr(args, "skip_if_no_db", False))
    test_type: str = args.type
    _print_header("Regression test installation")
    sys.stderr.write(f"  Host: {db.host}:{db.port}  User: {db.user}\n")
    sys.stderr.write(f"  Type: {test_type}\n\n")

    # Step 1: Install regression schema SQL
    sys.stderr.write("Step 1/3: Installing hafbe_test schema...\n")
    sql_files = sorted(REGRESSION_SQL_DIR.glob("*.sql"))
    if not sql_files:
        sys.stderr.write(f"{C_RED}  ERROR: no SQL files found in {REGRESSION_SQL_DIR}{C_RESET}\n")
        return 2
    for sql_file in sql_files:
        sys.stderr.write(f"  - installing {sql_file.name}\n")
        try:
            run_sql_file(db, sql_file)
        except (_PSYCOPG2_ERROR, FileNotFoundError) as exc:
            sys.stderr.write(f"{C_RED}    ERROR: {exc}{C_RESET}\n")
            return 3

    # Also install diagnostics so subsequent checks can use them
    try:
        _ensure_diagnostics_sql(db)
        sys.stderr.write("  - installing diagnostics.sql\n")
    except (_PSYCOPG2_ERROR, FileNotFoundError) as exc:
        sys.stderr.write(f"{C_YELLOW}    warning: {exc}{C_RESET}\n")

    sys.stderr.write("  done.\n\n")

    # Step 2: Load expected data for each requested type
    sys.stderr.write("Step 2/3: Loading expected data...\n")
    types_to_load: list[str] = []
    if test_type in ("account", "all"):
        types_to_load.append("account")
    if test_type in ("witness", "all"):
        types_to_load.append("witness")

    for dtype in types_to_load:
        sys.stderr.write(f"  - {dtype}: ")
        gz_name = "accounts_dump.json.gz" if dtype == "account" else "witnesses_dump.json.gz"
        gz_path = REGRESSION_DIR / gz_name
        if not gz_path.exists():
            sys.stderr.write(
                f"{C_RED}ERROR fixture missing: {gz_path}{C_RESET}\n"
            )
            return 2

        plain_path = _gunzip_if_needed(gz_path)
        data = json.loads(plain_path.read_text())

        if dtype == "account":
            records = data.get("result", {}).get("accounts", [])
            query_fn = "hafbe_test.load_expected_account_stats"
        else:
            records = data.get("result", [])
            query_fn = "hafbe_test.load_expected_witness_props"

        if not records:
            sys.stderr.write(f"{C_YELLOW}WARNING no records found in {gz_name}{C_RESET}\n")
            continue

        # Clear previous
        table_name = "expected_account_stats" if dtype == "account" else "expected_witness_props"
        try:
            run_sql(db, f"TRUNCATE hafbe_test.{table_name}")
        except _PSYCOPG2_ERROR as exc:
            sys.stderr.write(f"{C_RED}ERROR truncating: {exc}{C_RESET}\n")
            return 3

        # Batch insert via Python (mirrors load_expected_data.py)
        conn = db.connect()
        try:
            conn.autocommit = True
            cur = conn.cursor()
            for i, record in enumerate(records, 1):
                record_json = json.dumps(record)
                cur.execute(f"SELECT {query_fn}(%s)", (record_json,))
                if i % 1000 == 0:
                    sys.stderr.write(".")
                    sys.stderr.flush()
        except _PSYCOPG2_ERROR as exc:
            sys.stderr.write(f"\n{C_RED}    ERROR loading {dtype} data: {exc}{C_RESET}\n")
            return 3
        finally:
            conn.close()

        sys.stderr.write(f" loaded {len(records)} records\n")

        # Cleanup decompressed file to avoid stale fixtures
        plain_path.unlink(missing_ok=True)

    # Step 3: Post-install diagnostics
    sys.stderr.write("\nStep 3/3: Running post-install diagnostics...\n")
    any_fail = False
    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_regression_schema()")
        for schema, obj_type, obj_name, status in rows:
            if status == "FAIL":
                any_fail = True
                _print_status(f"{schema}.{obj_name}", status, obj_type)
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_YELLOW}  schema diagnostics skipped: {exc}{C_RESET}\n")

    try:
        rows = run_sql(db, "SELECT * FROM hafbe_backend.diagnose_expected_data_load()")
        for table_name, row_count, status, detail in rows:
            _print_status(f"{table_name}", status, f"{row_count} rows — {detail}")
            if status == "FAIL":
                any_fail = True
    except _PSYCOPG2_ERROR as exc:
        sys.stderr.write(f"{C_YELLOW}  expected-data diagnostics skipped: {exc}{C_RESET}\n")

    _print_header("Regression installation complete")
    if any_fail:
        sys.stderr.write(f"{C_RED}{C_BOLD}  ✗ Installation incomplete{C_RESET}\n")
        sys.stderr.write(
            f"{C_YELLOW}  Run './scripts/test_bootstrap.py check' for the full report.{C_RESET}\n\n"
        )
        return 1
    sys.stderr.write(f"{C_GREEN}{C_BOLD}  ✓ Regression schema + expected data ready{C_RESET}\n\n")
    sys.stderr.write("Next step:\n")
    sys.stderr.write("  ./scripts/test_bootstrap.py regression-run\n\n")
    return 0


# ---------------------------------------------------------------------------
# Subcommand: regression-run
# ---------------------------------------------------------------------------

def cmd_regression_run(args: argparse.Namespace) -> int:
    db = db_from_args(args)
    _preflight_db(db, getattr(args, "skip_if_no_db", False))
    test_type: str = args.type
    hafbe_schema: str = args.schema
    btracker_schema = os.environ.get("BTRACKER_SCHEMA", "hafbe_bal")

    _print_header("Regression test comparison")
    sys.stderr.write(f"  Host: {db.host}:{db.port}  User: {db.user}\n")
    sys.stderr.write(f"  Schema: {hafbe_schema}  Type: {test_type}\n\n")

    overall = 0

    # ---- Account tests ----
    if test_type in ("account", "all"):
        sys.stderr.write("--- Account regression ---\n")

        try:
            run_sql(db, "TRUNCATE hafbe_test.differing_accounts")
        except _PSYCOPG2_ERROR as exc:
            sys.stderr.write(f"{C_RED}  ERROR truncating differing_accounts: {exc}{C_RESET}\n")
            return 3

        try:
            run_sql(db, "SELECT hafbe_test.compare_accounts()",
                    set_search_path=hafbe_schema)
        except _PSYCOPG2_ERROR as exc:
            sys.stderr.write(f"{C_RED}  ERROR comparing accounts: {exc}{C_RESET}\n")
            return 3

        diff_count = run_sql(db, "SELECT COUNT(*) FROM hafbe_test.differing_accounts")
        n_diff = diff_count[0][0] if diff_count else 0

        if n_diff == 0:
            _print_status("account comparison", "PASS", "all accounts match")
        else:
            _print_status("account comparison", "FAIL",
                          f"{n_diff} accounts have discrepancies")
            sys.stderr.write(f"\n{C_YELLOW}  Sample differing accounts (first 10):{C_RESET}\n")
            samples = run_sql(db, """
                SELECT da.account_id, av.name
                FROM hafbe_test.differing_accounts da
                JOIN hive.accounts_view av ON av.id = da.account_id
                ORDER BY da.account_id
                LIMIT 10
            """)
            for aid, name in samples:
                sys.stderr.write(f"    - {name} (id={aid})\n")
            sys.stderr.write(
                f"  Debug: SELECT * FROM hafbe_test.get_account_comparison(<account_id>);\n\n"
            )
            overall = 1

    # ---- Witness tests ----
    if test_type in ("witness", "all"):
        sys.stderr.write("\n--- Witness regression ---\n")

        try:
            run_sql(db, "TRUNCATE hafbe_test.differing_witnesses")
        except _PSYCOPG2_ERROR as exc:
            sys.stderr.write(f"{C_RED}  ERROR truncating differing_witnesses: {exc}{C_RESET}\n")
            return 3

        try:
            run_sql(db, "SELECT hafbe_test.compare_witnesses()",
                    set_search_path=btracker_schema)
        except _PSYCOPG2_ERROR as exc:
            sys.stderr.write(f"{C_RED}  ERROR comparing witnesses: {exc}{C_RESET}\n")
            return 3

        diff_count = run_sql(db, "SELECT COUNT(*) FROM hafbe_test.differing_witnesses")
        n_diff = diff_count[0][0] if diff_count else 0

        if n_diff == 0:
            _print_status("witness comparison", "PASS", "all witnesses match")
        else:
            _print_status("witness comparison", "FAIL",
                          f"{n_diff} witnesses have discrepancies")
            sys.stderr.write(f"\n{C_YELLOW}  Sample differing witnesses (first 10):{C_RESET}\n")
            samples = run_sql(db, """
                SELECT dw.witness_id, av.name
                FROM hafbe_test.differing_witnesses dw
                JOIN hive.accounts_view av ON av.id = dw.witness_id
                ORDER BY dw.witness_id
                LIMIT 10
            """)
            for wid, name in samples:
                sys.stderr.write(f"    - {name} (id={wid})\n")
            sys.stderr.write(
                f"  Debug: SELECT * FROM hafbe_test.get_witness_comparison(<witness_id>);\n\n"
            )
            overall = 1

    _print_header("Regression summary")
    if overall == 0:
        sys.stderr.write(f"{C_GREEN}{C_BOLD}  ✓ All regression tests passed{C_RESET}\n\n")
    else:
        sys.stderr.write(f"{C_RED}{C_BOLD}  ✗ Some regression tests failed{C_RESET}\n\n")
    return overall


# ---------------------------------------------------------------------------
# Subcommand: regression-full
# ---------------------------------------------------------------------------

def cmd_regression_full(args: argparse.Namespace) -> int:
    rc = cmd_regression_install(args)
    if rc != 0:
        return rc
    return cmd_regression_run(args)


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="test_bootstrap.py",
        description=__doc__.splitlines()[3],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="\n".join(__doc__.splitlines()[-12:]),
    )
    sub = parser.add_subparsers(dest="command", required=True,
                                 metavar="<command>")

    def _mk(name: str, help_msg: str, handler) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=help_msg, description=help_msg)
        add_db_args(p)
        p.set_defaults(handler=handler)
        return p

    _mk("check",
        "Pre-flight diagnostics (schemas, tables, blocks, data)",
        cmd_check)

    _mk("mock-install",
        "Install mock SQL helpers, insert blocks/ops, rewind HAF contexts",
        cmd_mock_install)

    _mk("mock-verify",
        "Refresh caches and run mock verification with diagnostics",
        cmd_mock_verify)

    _mk("mock-full",
        "End-to-end mock pipeline: install → process → verify",
        cmd_mock_full)

    p_reg_install = _mk("regression-install",
                        "Install hafbe_test schema and load expected JSON dumps",
                        cmd_regression_install)
    p_reg_install.add_argument("--type", choices=["account", "witness", "all"],
                               default=os.environ.get("TEST_TYPE", "all"),
                               help="Which fixture to load (default: all or $TEST_TYPE)")

    p_reg_run = _mk("regression-run",
                    "Run account/witness comparison with detailed failure report",
                    cmd_regression_run)
    p_reg_run.add_argument("--type", choices=["account", "witness", "all"],
                           default=os.environ.get("TEST_TYPE", "all"),
                           help="Which comparison to run (default: all or $TEST_TYPE)")
    p_reg_run.add_argument("--schema",
                           default=os.environ.get("HAFBE_SCHEMA", "hafbe_app"),
                           help="HAFBE app schema name (default: hafbe_app or $HAFBE_SCHEMA)")

    p_reg_full = _mk("regression-full",
                     "End-to-end regression: install schema → load data → compare",
                     cmd_regression_full)
    p_reg_full.add_argument("--type", choices=["account", "witness", "all"],
                            default=os.environ.get("TEST_TYPE", "all"),
                            help="Which test to run end-to-end (default: all or $TEST_TYPE)")
    p_reg_full.add_argument("--schema",
                            default=os.environ.get("HAFBE_SCHEMA", "hafbe_app"),
                            help="HAFBE app schema name (default: hafbe_app or $HAFBE_SCHEMA)")

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    # Install the log-file tee BEFORE calling the handler so that every
    # diagnostic write – including unhandled-exception messages – is captured
    # on disk as well as printed to the terminal / CI log viewer.
    _install_log_file(getattr(args, "log_file", "") or None)

    try:
        return args.handler(args)
    except _PSYCOPG2_OPERATIONAL_ERROR as exc:
        sys.stderr.write(f"\n{C_RED}{C_BOLD}  Database connection error{C_RESET}\n")
        sys.stderr.write(f"  {exc}\n")
        sys.stderr.write(
            f"  Check that PostgreSQL is running and credentials are correct.\n\n"
        )
        return 3
    except KeyboardInterrupt:
        sys.stderr.write("\nInterrupted.\n")
        return 130


if __name__ == "__main__":
    sys.exit(main())
