# Ad Campaign Attribution & ROI Analysis Engine

A college-level, local analytics and data engineering project for comparing mobile advertising attribution models and understanding campaign performance, return on investment, and customer lifetime value.

**Current status:** PostgreSQL schema, environment loading, a minimal SQLAlchemy connection helper, and a schema initialization script are implemented. They have been inspected only and **have not been verified against a live PostgreSQL instance**. Synthetic data generation, journey reconstruction, attribution, metrics, optimization benchmarks, and dashboards remain unimplemented.

The source of truth for future implementation is [docs/PROJECT_SPEC.md](docs/PROJECT_SPEC.md).

## Planned architecture

```text
Synthetic Ad Events
        |
        v
PostgreSQL
        |
        v
User Journey Reconstruction
        |
        v
Attribution Engine
        |
        v
ROI / ROAS / LTV Analysis
        |
        v
Metabase
```

## Planned technology stack

- Python 3.12 for local scripts.
- PostgreSQL for storage and analytics queries.
- SQLAlchemy and psycopg2-binary for database access.
- Pandas for tabular analysis.
- python-dotenv for local environment configuration.
- Pytest for future tests.
- Metabase for dashboards connected directly to PostgreSQL.

## Repository structure

```text
.
|-- data/
|   |-- raw/             # Raw input files
|   |   `-- .gitkeep
|   `-- generated/       # Future synthetic datasets
|       `-- .gitkeep
|-- scripts/             # Local database setup
|   |-- db.py
|   |-- init_db.py
|   `-- .gitkeep
|-- sql/                 # SQL is the schema source of truth
|   |-- schema.sql
|   `-- .gitkeep
|-- notebooks/           # Future exploratory analysis
|   `-- .gitkeep
|-- tests/               # Future tests; none implemented or executed
|   `-- .gitkeep
|-- docs/
|   `-- PROJECT_SPEC.md
|-- .env.example
|-- .gitignore
|-- README.md
`-- requirements.txt
```

## Setup prerequisites and instructions

Install Python 3.12, Git, and PostgreSQL, and use Windows PowerShell from the repository root. Metabase will be required at the later dashboard milestone. The scripts do not install or start PostgreSQL, create database users, or create the database itself.

Create and activate a virtual environment, then install the Python dependencies:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

If PowerShell blocks activation, use a session-scoped execution policy, where your machine's policy permits it, and retry:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\.venv\Scripts\Activate.ps1
```

Create an empty database manually using pgAdmin or an existing PostgreSQL administrator connection in `psql`:

```sql
CREATE DATABASE ad_attribution;
```

Copy the configuration template:

```powershell
Copy-Item .env.example .env
```

Edit the local `.env` and replace the placeholder username, password, host, and port in `DATABASE_URL` with your local PostgreSQL settings. URL-encode special characters in credentials. `.env` and `.venv/` are ignored by Git; no real `.env` file is included. The helper loads `.env` relative to the repository root and preserves existing process environment variables.

After configuring the database and credentials, initialize the schema:

```powershell
python scripts/init_db.py
```

This command opens a live database connection and executes `sql/schema.sql` in one transaction. It is intended for a fresh, empty database. A repeat run fails on existing tables and rolls back; it does not drop tables or silently skip existing definitions. These setup commands are instructions for manual use and were not executed during this milestone.

For future scripts in `scripts/`, use `from db import get_engine`, create `engine = get_engine()`, and manage connections with `with engine.connect() as connection:`. Call `engine.dispose()` when finished. Code imported from the repository root can use `from scripts.db import get_engine`. `get_connection()` is also available for a simple connection context. Importing the helper or calling `get_engine()` does not connect; opening a connection does. The template retains a seven-day attribution-window setting; attribution-window parsing is deferred.

## Database foundation

The nine tables are `users`, `channels`, `campaigns`, `creatives`, `impressions`, `clicks`, `conversions`, `campaign_spend`, and `user_revenue`.

Channels own campaigns; campaigns own creatives. Impressions and clicks reference a user, campaign, and matching creative. Conversions and revenue reference users; daily spend references campaigns and is unique per campaign/date. All foreign keys use restrictive deletion to protect history. Conversions have no attributed campaign field.

Money uses nonnegative `NUMERIC(18, 6)` in one project-wide currency. Event timestamps use `TIMESTAMPTZ`. Signup dates can be absent before acquisition; campaign end dates can be absent for ongoing campaigns. Country values are intended as two-letter codes. Device and creative types remain text fields without separate type tables.

Initial indexes cover user/time lookups on impressions, clicks, conversions, and revenue, plus campaign/time lookups on impressions and clicks. Primary keys and unique constraints provide their own indexes, including campaign/date spend uniqueness. No materialized views or benchmarks exist yet.

Dependencies are deliberately unpinned in this initial scaffold. Version pinning can follow once the implementation is checked with Python 3.12.

**Validation for this milestone is limited to lightweight source-code and file inspection. No tests, database initialization, dependency installation, benchmarks, or expensive workloads were run.**

## Planned milestones

1. **Completed: repository scaffold and project specification.**
2. **Implemented: PostgreSQL schema and local database configuration.** Live PostgreSQL verification is pending.
3. **Next: small, reproducible synthetic dataset with distinct channel behavior**, stored in PostgreSQL after manual schema setup.
4. User journey reconstruction with a configurable attribution window.
5. First-click, last-click, and linear attribution.
6. Campaign metrics, simple LTV/cohort analysis, and model comparison.
7. One measured PostgreSQL query optimization using `EXPLAIN ANALYZE` before and after the change.
8. Metabase Campaign Overview, Attribution Model Comparison, and LTV / Cohort Analysis dashboards.
