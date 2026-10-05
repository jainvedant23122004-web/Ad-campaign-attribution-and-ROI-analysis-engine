"""Minimal PostgreSQL configuration and connection helpers; SQL defines the schema."""

import os
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.engine import Connection, Engine, make_url
from sqlalchemy.exc import ArgumentError


def get_engine() -> Engine:
    """Load the root .env and build an engine without opening a connection."""
    project_root = Path(__file__).resolve().parent.parent
    load_dotenv(project_root / ".env", override=False)
    database_url = os.getenv("DATABASE_URL", "").strip()
    if not database_url:
        raise ValueError(
            "DATABASE_URL is missing. Copy .env.example to .env in the project "
            "root and configure your PostgreSQL credentials."
        )

    try:
        url = make_url(database_url)
    except (ArgumentError, ValueError):
        raise ValueError("DATABASE_URL must be a valid PostgreSQL connection URL.") from None
    if url.get_backend_name() != "postgresql":
        raise ValueError("DATABASE_URL must use PostgreSQL (postgresql://...).")

    return create_engine(url, pool_pre_ping=True)


def get_connection() -> Connection:
    """Open a connection; callers should close it with a 'with' statement."""
    return get_engine().connect()
