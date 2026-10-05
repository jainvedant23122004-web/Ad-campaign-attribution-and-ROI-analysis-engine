"""Measure just the cohort report: exact reconciliation, then three paired runs."""

import argparse
import json
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from statistics import median
from time import perf_counter

from sqlalchemy import event, text
from sqlalchemy.exc import SQLAlchemyError

if __package__:
    from .db import get_engine
else:
    from db import get_engine


ROOT = Path(__file__).resolve().parent.parent
EXPLAIN_PREFIX = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)"


def read_report(filename: str) -> tuple[str, str]:
    """Read the two explicitly marked sections of our fixed report SQL files."""
    contents = (ROOT / "sql" / filename).read_text(encoding="utf-8")
    query = contents.split("-- BEGIN QUERY\n", 1)[1].split("-- END QUERY", 1)[0].strip()
    explain = contents.split("-- BEGIN EXPLAIN\n", 1)[1].split("-- END EXPLAIN", 1)[0].strip()
    if explain != f"{EXPLAIN_PREFIX}\n{query}":
        raise ValueError(f"Query and EXPLAIN sections differ in {filename}.")
    return query, explain


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup", action="store_true",
                        help="Create if absent and refresh only the cohort materialized view first.")
    parser.add_argument("--output", type=Path,
                        help="Optionally save timings, context, SQL, and all six JSON plans.")
    args = parser.parse_args()
    engine = None
    try:
        reports = {
            "baseline": read_report("optimization_baseline.sql"),
            "optimized": read_report("optimization_after.sql"),
        }
        checks = (ROOT / "sql" / "optimization_checks.sql").read_text(encoding="utf-8")
        engine = get_engine()

        @event.listens_for(engine, "do_connect")
        def bound_connect(dialect, record, connection_args, parameters):
            parameters["connect_timeout"] = 5

        setup_elapsed_ms = None
        if args.setup:
            setup_sql = (ROOT / "sql" / "optimization.sql").read_text(encoding="utf-8")
            with engine.begin() as connection:
                connection.exec_driver_sql("SET LOCAL lock_timeout = '5s'")
                connection.exec_driver_sql("SET LOCAL statement_timeout = '15s'")
                if not connection.scalar(text(
                    "SELECT pg_try_advisory_xact_lock("
                    "hashtext('ad_attribution'), hashtext('cohort_optimization_setup'))"
                )):
                    raise ValueError("Another cohort optimization setup is running. Retry later.")
                started = perf_counter()
                connection.exec_driver_sql(setup_sql)
                setup_elapsed_ms = (perf_counter() - started) * 1000
            print("Cohort materialized view created/refreshed; source tables unchanged.")

        # A single stable snapshot covers equivalence and every measured run.
        # No planner settings, cache flushes, data changes, or prepared query reuse.
        with engine.connect().execution_options(isolation_level="REPEATABLE READ") as connection:
            with connection.begin():
                connection.exec_driver_sql("SET TRANSACTION READ ONLY")
                connection.exec_driver_sql("SET LOCAL lock_timeout = '5s'")
                connection.exec_driver_sql("SET LOCAL statement_timeout = '15s'")
                context = dict(connection.execute(text("""
                    SELECT current_setting('server_version') AS postgres_version,
                           current_setting('TimeZone') AS session_timezone,
                           current_setting('work_mem') AS work_mem,
                           current_setting('jit') AS jit,
                           current_setting('track_io_timing') AS track_io_timing,
                           current_setting('max_parallel_workers_per_gather') AS max_parallel_workers_per_gather,
                           (SELECT COUNT(*) FROM conversions) AS conversions,
                           (SELECT COUNT(*) FROM attribution_results) AS attribution_rows,
                           (SELECT COUNT(*) FROM user_revenue) AS revenue_rows,
                           (SELECT COUNT(*) FROM campaign_spend) AS spend_rows
                """)).one()._mapping)
                equivalence = dict(connection.exec_driver_sql(checks).one()._mapping)
                if equivalence["missing_rows"] or equivalence["extra_rows"]:
                    raise ValueError("Cohort results differ. Refresh/inspect the materialized view; no timings accepted.")
                if equivalence["baseline_rows"] == 0:
                    raise ValueError("The cohort report is empty; this is not a meaningful measurement.")

                # Reconciliation reads both reports and acts as shared warm-up.
                # Fixed, alternating B1/A1/B2/A2/B3/A3; no favorable-run selection.
                runs = []
                for run_number in range(1, 4):
                    for label, (_, explain) in reports.items():
                        document = connection.exec_driver_sql(explain).scalar_one()
                        if isinstance(document, str):
                            document = json.loads(document)
                        plan = document[0]
                        root = plan["Plan"]
                        runs.append({
                            "query": label,
                            "run": run_number,
                            "planning_ms": plan["Planning Time"],
                            "execution_ms": plan["Execution Time"],
                            "shared_hit_blocks": root.get("Shared Hit Blocks", 0),
                            "shared_read_blocks": root.get("Shared Read Blocks", 0),
                            "result_rows": root["Actual Rows"],
                            "explain": plan,
                        })

        before = median(Decimal(str(r["execution_ms"])) for r in runs if r["query"] == "baseline")
        after = median(Decimal(str(r["execution_ms"])) for r in runs if r["query"] == "optimized")
        if before <= 0:
            raise ValueError("Baseline is below timing resolution; cannot calculate improvement.")
        improvement = (before - after) / before * 100
        result = {
            "measured_at_utc": datetime.now(timezone.utc).isoformat(),
            "method": "Exact reconciliation warm-up; three alternating pairs; one read-only repeatable-read snapshot.",
            "context": context,
            "queries": {label: query for label, (query, _) in reports.items()},
            "equivalence": equivalence,
            "setup_client_elapsed_ms": setup_elapsed_ms,
            "runs": runs,
            "baseline_median_ms": str(before),
            "optimized_median_ms": str(after),
            "improvement_percentage": str(improvement),
        }
        if args.output:
            args.output.write_text(json.dumps(result, indent=2, default=str) + "\n", encoding="utf-8")
        print(f"Exact equivalence: {equivalence['baseline_rows']} rows; "
              f"missing={equivalence['missing_rows']}, extra={equivalence['extra_rows']}.")
        for run in runs:
            print(f"{run['query']} run {run['run']}: execution={run['execution_ms']:.3f} ms, "
                  f"planning={run['planning_ms']:.3f} ms, "
                  f"shared hit/read={run['shared_hit_blocks']}/{run['shared_read_blocks']}")
        print(f"Median execution: baseline={before} ms, optimized={after} ms.")
        print(f"Measured change: {improvement:.6f}% "
              "(positive = faster; negative = slower).")
        if setup_elapsed_ms is not None:
            print(f"Setup/refresh client elapsed: {setup_elapsed_ms:.3f} ms "
                  "(separate from PostgreSQL report execution timings).")
        if args.output:
            print(f"Raw measurement saved to {args.output}.")
    except (OSError, ValueError, IndexError) as error:
        print(f"Scoped benchmark failed: {error}", file=sys.stderr)
        return 1
    except SQLAlchemyError as error:
        original = getattr(error, "orig", None)
        sqlstate = getattr(original, "sqlstate", None) or getattr(original, "pgcode", None)
        print(f"Scoped benchmark failed (SQLSTATE: {sqlstate or 'unavailable'}). "
              "Check connectivity, existing cohort views, and read/creation/refresh permissions. "
              "No source rows were modified; --setup commits separately before measurement.",
              file=sys.stderr)
        return 1
    finally:
        if engine is not None:
            engine.dispose()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
