"""Create or replace ordinary LTV/CAC/cohort views transactionally."""

import sys
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

if __package__:
    from .db import get_engine
else:
    from db import get_engine


def main() -> int:
    sql_path = Path(__file__).resolve().parent.parent / "sql" / "ltv_cohorts.sql"
    engine = None
    try:
        ltv_sql = sql_path.read_text(encoding="utf-8")
        engine = get_engine()
        with engine.begin() as connection:
            connection.exec_driver_sql("SET LOCAL lock_timeout = '5s'")
            connection.exec_driver_sql("SET LOCAL statement_timeout = '30s'")
            owns_setup_lock = connection.scalar(text(
                "SELECT pg_try_advisory_xact_lock("
                "hashtext('ad_attribution'), hashtext('ltv_views_setup'))"
            ))
            if not owns_setup_lock:
                raise ValueError("Another LTV setup is running. Retry after it finishes.")
            connection.exec_driver_sql(ltv_sql)
    except (OSError, ValueError) as error:
        print(f"LTV setup failed: {error}", file=sys.stderr)
        return 1
    except SQLAlchemyError as error:
        original = getattr(error, "orig", None)
        sqlstate = getattr(original, "sqlstate", None) or getattr(original, "pgcode", None)
        print(
            f"LTV setup failed (SQLSTATE: {sqlstate or 'unavailable'}). "
            "Check connectivity, existing source/attribution tables, "
            "and view creation/ownership permissions. No view changes were committed.",
            file=sys.stderr,
        )
        return 1
    finally:
        if engine is not None:
            engine.dispose()

    print("LTV views created successfully: user_acquisition, user_ltv, "
          "campaign_ltv, channel_ltv, acquisition_cohort_ltv.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
