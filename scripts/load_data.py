"""Load generated CSVs into empty project tables in one PostgreSQL transaction."""

import csv
import sys
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, InvalidOperation

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

if __package__:
    from .db import get_engine
    from .generate_data import MONEY_COLUMNS, NULLABLE_COLUMNS, OUTPUT_DIR, TABLE_COLUMNS, validate_dataset
else:
    from db import get_engine
    from generate_data import MONEY_COLUMNS, NULLABLE_COLUMNS, OUTPUT_DIR, TABLE_COLUMNS, validate_dataset


BATCH_SIZE = 1_000


def read_csvs() -> dict[str, list[dict]]:
    """Read exact schema columns and restore dates, timestamps, and exact money."""
    missing = [f"{table}.csv" for table in TABLE_COLUMNS if not (OUTPUT_DIR / f"{table}.csv").is_file()]
    if missing:
        raise ValueError("Missing generated CSVs: " + ", ".join(missing) + ". Run generate_data.py first.")

    data = {}
    for table, columns in TABLE_COLUMNS.items():
        data[table] = []
        with (OUTPUT_DIR / f"{table}.csv").open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if tuple(reader.fieldnames or ()) != columns:
                raise ValueError(f"Unexpected CSV columns in {table}.csv; regenerate the dataset.")
            for line_number, raw in enumerate(reader, start=2):
                if set(raw) != set(columns) or any(value is None for value in raw.values()):
                    raise ValueError(f"Malformed CSV row in {table}.csv at line {line_number}.")
                row = {}
                for column, value in raw.items():
                    try:
                        if value == "" and column in NULLABLE_COLUMNS:
                            row[column] = None
                        elif column.endswith("_id"):
                            row[column] = int(value)
                        elif column in MONEY_COLUMNS:
                            row[column] = Decimal(value)
                        elif column == "created_at" or column.endswith("_time"):
                            row[column] = datetime.fromisoformat(value)
                        elif column.endswith("_date"):
                            row[column] = date.fromisoformat(value)
                        else:
                            row[column] = value
                    except (ValueError, InvalidOperation):
                        raise ValueError(
                            f"Invalid {column} in {table}.csv at line {line_number}."
                        ) from None
                data[table].append(row)

    if not data["campaigns"] or any(row["end_date"] is None for row in data["campaigns"]):
        raise ValueError("Generated campaigns must specify an observation start and end date.")
    start_date = min(row["start_date"] for row in data["campaigns"])
    end_date = max(row["end_date"] for row in data["campaigns"]) + timedelta(days=1)
    start = datetime.combine(start_date, time.min, tzinfo=timezone.utc)
    end = datetime.combine(end_date, time.min, tzinfo=timezone.utc)
    validate_dataset(data, start, end)
    return data


def load_dataset(data: dict[str, list[dict]]) -> None:
    """Serialize loads, refuse existing rows, and preserve CSV identity keys."""
    engine = get_engine()
    try:
        with engine.begin() as connection:
            connection.exec_driver_sql("SET LOCAL lock_timeout = '5s'")
            connection.exec_driver_sql("SET LOCAL statement_timeout = '60s'")
            # Known project table names only. This lock prevents concurrent loaders
            # or inserts from racing the empty-table checks; ordinary reads can continue.
            connection.exec_driver_sql(
                f"LOCK TABLE {', '.join(TABLE_COLUMNS)} IN SHARE ROW EXCLUSIVE MODE"
            )
            populated = [table for table in TABLE_COLUMNS
                         if connection.scalar(text(f"SELECT EXISTS (SELECT 1 FROM {table})"))]
            if populated:
                raise ValueError(
                    "Load refused: project tables already contain data ("
                    + ", ".join(populated) + "). No data was changed."
                )

            for table, columns in TABLE_COLUMNS.items():
                # The existing schema uses GENERATED ALWAYS AS IDENTITY. Explicit
                # CSV IDs preserve foreign keys and require OVERRIDING SYSTEM VALUE.
                insert = text(
                    f"INSERT INTO {table} ({', '.join(columns)}) OVERRIDING SYSTEM VALUE "
                    f"VALUES ({', '.join(':' + column for column in columns)})"
                )
                rows = data[table]
                for offset in range(0, len(rows), BATCH_SIZE):
                    connection.execute(insert, rows[offset:offset + BATCH_SIZE])

            # Explicit inserts do not advance identity sequences. RESTART is
            # transactional (unlike setval) so failures also roll back these changes.
            # This operation requires table ownership, as documented in the README.
            for table, columns in TABLE_COLUMNS.items():
                primary_key = columns[0]
                next_id = max((row[primary_key] for row in data[table]), default=0) + 1
                connection.exec_driver_sql(
                    f"ALTER TABLE {table} ALTER COLUMN {primary_key} RESTART WITH {next_id}"
                )
    finally:
        engine.dispose()


def main() -> int:
    try:
        data = read_csvs()  # Validate the entire dataset before opening a connection.
        load_dataset(data)
    except (ValueError, OSError, csv.Error) as error:
        print(f"Load failed: {error}", file=sys.stderr)
        return 1
    except SQLAlchemyError as error:
        original = getattr(error, "orig", None)
        sqlstate = getattr(original, "sqlstate", None) or getattr(original, "pgcode", None)
        print(
            f"PostgreSQL load failed (SQLSTATE: {sqlstate or 'unavailable'}). "
            "Check DATABASE_URL, connectivity, schema initialization, and table ownership. "
            "The load transaction was rolled back; no dataset rows were committed.",
            file=sys.stderr,
        )
        return 1

    print("Synthetic dataset loaded successfully in one transaction.")
    for table, rows in data.items():
        print(f"{table:16} {len(rows):>8,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
