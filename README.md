# Ad Campaign Attribution & ROI Analysis Engine

A college-level, local analytics and data engineering project for comparing mobile advertising attribution models and understanding campaign performance, return on investment, and customer lifetime value.

**Current status:** repository scaffold only. The database schema, synthetic data generator, journey reconstruction, attribution engine, metrics, optimization benchmarks, and dashboards have not been implemented. No business logic exists yet.

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
|-- scripts/             # Future local Python scripts
|   `-- .gitkeep
|-- sql/                 # Future schema and analytics SQL
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

Install Python 3.12 and Git, and use Windows PowerShell from the repository root. PostgreSQL will be required in later implementation stages; Metabase will be required at the dashboard milestone. Neither service is configured by this scaffold.

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

When configuring the database in a later milestone, copy the configuration template and replace the placeholder credentials locally:

```powershell
Copy-Item .env.example .env
```

`.env` and `.venv/` are ignored by Git. No real `.env` file is included. The template records a planned default attribution window of 7 days; configuration loading has not been implemented.

Dependencies are deliberately unpinned in this initial scaffold. Version pinning can follow once the implementation is checked with Python 3.12.

**Scaffolding validation is limited to lightweight file inspection. Do not run test commands, automated validation frameworks, database benchmarks, or expensive workloads during this step.**

## Planned milestones

1. **Completed: repository scaffold and project specification.**
2. **Next: PostgreSQL schema and local database configuration.** Define the core tables, relationships, and constraints in `sql/`, and add a minimal environment configuration and database connection script in `scripts/`.
3. Small, reproducible synthetic dataset with distinct channel behavior.
4. User journey reconstruction with a configurable attribution window.
5. First-click, last-click, and linear attribution.
6. Campaign metrics, simple LTV/cohort analysis, and model comparison.
7. One measured PostgreSQL query optimization using `EXPLAIN ANALYZE` before and after the change.
8. Metabase Campaign Overview, Attribution Model Comparison, and LTV / Cohort Analysis dashboards.
