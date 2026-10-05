"""Initialize an existing, empty PostgreSQL database from sql/schema.sql."""

import sys
from pathlib import Path

from sqlalchemy.exc import OperationalError, SQLAlchemyError

if __package__:
    from .db import get_engine
else:
    from db import get_engine


def main() -> int:
    """Apply the schema atomically; return a nonzero exit code on failure."""
    schema_path = Path(__file__).resolve().parent.parent / "sql" / "schema.sql"
    engine = None
    try:
        schema_sql = schema_path.read_text(encoding="utf-8")
        engine = get_engine()
        with engine.begin() as connection:
            connection.exec_driver_sql(schema_sql)
    except OSError:
        print(f"Cannot read schema file: {schema_path}", file=sys.stderr)
        return 1
    except ValueError as error:
        print(f"Database configuration error: {error}", file=sys.stderr)
        return 1
    except OperationalError:
        print(
            "Could not initialize PostgreSQL. Check that the server is reachable, "
            "the ad_attribution database exists, and DATABASE_URL credentials "
            "and database permissions are correct.",
            file=sys.stderr,
        )
        return 1
    except SQLAlchemyError as error:
        # Avoid printing connection URLs, credentials, or the full SQL statement.
        sqlstate = getattr(getattr(error, "orig", None), "pgcode", None)
        if sqlstate == "42P07":
            message = "A schema table already exists. Use a fresh, empty database."
        else:
            message = "Check schema.sql and database schema-creation permissions."
        print(
            f"Schema initialization failed (SQLSTATE: {sqlstate or 'unavailable'}). "
            f"{message} No schema changes were committed.",
            file=sys.stderr,
        )
        return 1
    finally:
        if engine is not None:
            engine.dispose()

    print("PostgreSQL schema initialized successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
