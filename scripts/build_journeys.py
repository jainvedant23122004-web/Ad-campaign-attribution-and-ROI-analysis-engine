"""Build eligible conversion touchpoints in PostgreSQL without assigning credit."""

import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

if __package__:
    from .db import get_engine
else:
    from db import get_engine


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def resolve_window_days(cli_window: int | None) -> int:
    """Precedence: CLI, process environment, root .env, then seven days."""
    load_dotenv(PROJECT_ROOT / ".env", override=False)
    value = cli_window if cli_window is not None else os.getenv("ATTRIBUTION_WINDOW_DAYS", "7")
    try:
        window_days = int(value)
    except (TypeError, ValueError):
        raise ValueError("ATTRIBUTION_WINDOW_DAYS/--window-days must be a positive integer.") from None
    if not 0 < window_days <= 2**31 - 1:
        raise ValueError("The attribution window must be a positive PostgreSQL INTEGER number of days.")
    return window_days


def build_journeys(window_days: int, rebuild: bool = False) -> dict:
    """Create the intermediate table and populate it atomically from source events."""
    if not isinstance(window_days, int) or not 0 < window_days <= 2**31 - 1:
        raise ValueError("window_days must be a positive PostgreSQL INTEGER.")
    schema_sql = (PROJECT_ROOT / "sql" / "journeys.sql").read_text(encoding="utf-8")
    reconstruction_sql = (PROJECT_ROOT / "sql" / "build_journeys.sql").read_text(encoding="utf-8")
    engine = get_engine()
    try:
        with engine.begin() as connection:
            connection.exec_driver_sql("SET LOCAL lock_timeout = '5s'")
            connection.exec_driver_sql("SET LOCAL statement_timeout = '60s'")
            connection.exec_driver_sql("SET LOCAL TIME ZONE 'UTC'")
            # Serialize even the first table creation; the lock releases with the
            # transaction. Fixed names keep independent script invocations aligned.
            owns_build_lock = connection.scalar(text(
                "SELECT pg_try_advisory_xact_lock("
                "hashtext('ad_attribution'), hashtext('conversion_touchpoints_build'))"
            ))
            if not owns_build_lock:
                raise ValueError("Another journey build is running. Retry after it finishes.")
            # SHARE locks keep source events/relationships stable during this small
            # build while permitting readers. No source data is modified.
            connection.exec_driver_sql(
                "LOCK TABLE users, channels, campaigns, creatives, impressions, "
                "clicks, conversions IN SHARE MODE"
            )
            connection.exec_driver_sql(schema_sql)
            # Serialize the populated-table check, rebuild, and insert operations.
            connection.exec_driver_sql(
                "LOCK TABLE conversion_touchpoints IN SHARE ROW EXCLUSIVE MODE"
            )
            has_rows = connection.scalar(text("SELECT EXISTS (SELECT 1 FROM conversion_touchpoints)"))
            if has_rows and not rebuild:
                raise ValueError(
                    "conversion_touchpoints already contains rows. Use --rebuild "
                    "to replace only the intermediate journey rows."
                )
            if rebuild:
                connection.exec_driver_sql("DELETE FROM conversion_touchpoints")
            connection.execute(text(reconstruction_sql), {"window_days": window_days})

            # Summary counts include conversions with no eligible advertising event.
            summary = dict(connection.execute(text("""
                SELECT
                    (SELECT COUNT(*) FROM conversions) AS conversions_processed,
                    COUNT(*) AS eligible_touchpoints,
                    COUNT(*) FILTER (WHERE touchpoint_type = 'impression') AS impression_touchpoints,
                    COUNT(*) FILTER (WHERE touchpoint_type = 'click') AS click_touchpoints,
                    COUNT(DISTINCT conversion_id) AS conversions_with_touchpoints
                FROM conversion_touchpoints
            """)).mappings().one())
    finally:
        engine.dispose()

    summary["conversions_without_touchpoints"] = (
        summary["conversions_processed"] - summary["conversions_with_touchpoints"]
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window-days", type=int, default=None, help="Override the configured window (default 7)")
    parser.add_argument("--rebuild", action="store_true", help="Replace only existing conversion touchpoints")
    args = parser.parse_args()
    try:
        window_days = resolve_window_days(args.window_days)
        if args.rebuild:
            print("Rebuilding conversion_touchpoints only; source event data will be preserved.")
        summary = build_journeys(window_days, rebuild=args.rebuild)
    except (ValueError, OSError) as error:
        print(f"Journey reconstruction failed: {error}", file=sys.stderr)
        return 1
    except SQLAlchemyError as error:
        original = getattr(error, "orig", None)
        sqlstate = getattr(original, "sqlstate", None) or getattr(original, "pgcode", None)
        print(
            f"Journey reconstruction failed (SQLSTATE: {sqlstate or 'unavailable'}). "
            "Check connectivity, initialized source tables, permissions, and journey SQL. "
            "No journey changes were committed; source data was not modified.",
            file=sys.stderr,
        )
        return 1

    print("Journey reconstruction complete.")
    for label, key in (
        ("Conversions processed", "conversions_processed"),
        ("Eligible touchpoints", "eligible_touchpoints"),
        ("Impression touchpoints", "impression_touchpoints"),
        ("Click touchpoints", "click_touchpoints"),
        ("Conversions with touchpoints", "conversions_with_touchpoints"),
        ("Conversions with no touchpoint", "conversions_without_touchpoints"),
    ):
        print(f"{label + ':':33} {summary[key]:>10,}")
    total_conversions = summary["conversions_processed"]
    average = summary["eligible_touchpoints"] / total_conversions if total_conversions else 0
    print(f"Average touchpoints/conversion:    {average:>10.2f}")
    print(f"Attribution window:               {window_days:>10} days")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
