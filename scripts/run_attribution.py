"""Assign first-click, last-click, and linear credit to eligible click touchpoints."""

import argparse
import sys
from decimal import Decimal
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

if __package__:
    from .db import get_engine
else:
    from db import get_engine


PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODELS = ("first_click", "last_click", "linear")
WEIGHT_TOLERANCE = Decimal("0.000000000001")
VALUE_TOLERANCE = Decimal("0.000001")


def run_attribution(rebuild: bool = False) -> dict:
    """Populate and validate all three models in one transaction."""
    sql_dir = PROJECT_ROOT / "sql"
    schema_sql = (sql_dir / "attribution.sql").read_text(encoding="utf-8")
    attribution_sql = (sql_dir / "run_attribution.sql").read_text(encoding="utf-8")
    validation_sql = (sql_dir / "validate_attribution.sql").read_text(encoding="utf-8")
    engine = get_engine()
    try:
        with engine.begin() as connection:
            connection.exec_driver_sql("SET LOCAL lock_timeout = '5s'")
            connection.exec_driver_sql("SET LOCAL statement_timeout = '60s'")
            connection.exec_driver_sql("SET LOCAL TIME ZONE 'UTC'")
            owns_build_lock = connection.scalar(text(
                "SELECT pg_try_advisory_xact_lock("
                "hashtext('ad_attribution'), hashtext('attribution_results_build'))"
            ))
            if not owns_build_lock:
                raise ValueError("Another attribution run is active. Retry after it finishes.")
            # Keep source relationships, values, and eligibility stable for the run.
            # These locks permit ordinary readers; no source or journey rows change.
            connection.exec_driver_sql(
                "LOCK TABLE users, channels, campaigns, creatives, impressions, "
                "clicks, conversions, conversion_touchpoints IN SHARE MODE"
            )
            connection.exec_driver_sql(schema_sql)
            connection.exec_driver_sql(
                "LOCK TABLE attribution_results IN SHARE ROW EXCLUSIVE MODE"
            )
            has_rows = connection.scalar(text("SELECT EXISTS (SELECT 1 FROM attribution_results)"))
            if has_rows and not rebuild:
                raise ValueError(
                    "attribution_results already contains rows. Use --rebuild "
                    "to replace only attribution results."
                )

            # Denormalized journeys are snapshots. Refuse stale/inconsistent click
            # rows rather than credit a different user, timestamp, campaign, or channel.
            stale_journeys = connection.scalar(text("""
                SELECT EXISTS (
                    SELECT 1
                    FROM conversion_touchpoints AS t
                    JOIN conversions AS c ON c.conversion_id = t.conversion_id
                    JOIN clicks AS cl ON cl.click_id = t.click_id
                    JOIN campaigns AS ca ON ca.campaign_id = cl.campaign_id
                    WHERE t.touchpoint_type = 'click'
                      AND (t.user_id <> c.user_id OR t.user_id <> cl.user_id
                           OR t.conversion_time <> c.conversion_time
                           OR t.touchpoint_time <> cl.click_time
                           OR t.campaign_id <> cl.campaign_id
                           OR t.creative_id <> cl.creative_id
                           OR t.channel_id <> ca.channel_id)
                )
            """))
            if stale_journeys:
                raise ValueError(
                    "Eligible click journeys do not match current source data. "
                    "Rebuild journeys before running attribution."
                )

            if rebuild:
                connection.exec_driver_sql("DELETE FROM attribution_results")
            connection.execute(text(attribution_sql))
            violations = connection.execute(text(validation_sql), {
                "weight_tolerance": WEIGHT_TOLERANCE,
                "value_tolerance": VALUE_TOLERANCE,
            }).mappings().all()
            if violations:
                first = violations[0]
                raise ValueError(
                    f"Attribution validation failed for conversion {first['conversion_id']} "
                    f"({first['attribution_model']}): {first['reason']}. "
                    "All changes were rolled back."
                )

            summary = dict(connection.execute(text("""
                SELECT
                    (SELECT COUNT(*) FROM conversions) AS conversions_total,
                    (SELECT COUNT(DISTINCT conversion_id)
                     FROM conversion_touchpoints
                     WHERE touchpoint_type = 'click') AS conversions_with_clicks
            """)).mappings().one())
            model_counts = connection.execute(text("""
                SELECT attribution_model, COUNT(*) AS row_count
                FROM attribution_results
                GROUP BY attribution_model
            """)).mappings().all()
            summary["model_rows"] = {model: 0 for model in MODELS}
            summary["model_rows"].update({row["attribution_model"]: row["row_count"] for row in model_counts})
    finally:
        engine.dispose()

    summary["conversions_without_clicks"] = summary["conversions_total"] - summary["conversions_with_clicks"]
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rebuild", action="store_true", help="Replace only existing attribution results")
    args = parser.parse_args()
    try:
        if args.rebuild:
            print("Rebuilding attribution_results only; source events and journeys will be preserved.")
        summary = run_attribution(rebuild=args.rebuild)
    except (ValueError, OSError) as error:
        print(f"Attribution failed: {error}", file=sys.stderr)
        return 1
    except SQLAlchemyError as error:
        original = getattr(error, "orig", None)
        sqlstate = getattr(original, "sqlstate", None) or getattr(original, "pgcode", None)
        print(
            f"Attribution failed (SQLSTATE: {sqlstate or 'unavailable'}). "
            "Check connectivity, initialized source/journey tables, permissions, and attribution SQL. "
            "No attribution changes were committed; source events and journeys were not modified.",
            file=sys.stderr,
        )
        return 1

    print("Attribution complete.")
    for label, key in (
        ("Conversions total", "conversions_total"),
        ("Conversions with eligible clicks", "conversions_with_clicks"),
        ("Conversions without eligible clicks", "conversions_without_clicks"),
    ):
        print(f"{label + ':':38} {summary[key]:>10,}")
    for model in MODELS:
        print(f"{model + ' rows:':38} {summary['model_rows'][model]:>10,}")
    for model in MODELS:
        print(f"{model + ' weight/value validation:':38} OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
