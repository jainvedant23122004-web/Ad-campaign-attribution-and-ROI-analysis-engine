# Ad Campaign Attribution & ROI Analysis Engine

A college-level, local analytics and data engineering project for comparing mobile advertising attribution models and understanding campaign performance, return on investment, and customer lifetime value.

**Current status:** PostgreSQL schema/setup, synthetic CSV generation/loading, and SQL-based journey reconstruction are implemented. The journey builder has been inspected only and **has not been executed or verified against a live database during this milestone**. Attribution credit assignment, metrics, optimization benchmarks, and dashboards remain unimplemented.

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
- SQLAlchemy and Psycopg 3 (`psycopg[binary]`) for database access.
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
|   `-- generated/       # Nine CSVs written when generation is run manually
|       `-- .gitkeep
|-- scripts/             # Database setup, data generation/loading, and journeys
|   |-- build_journeys.py
|   |-- db.py
|   |-- generate_data.py
|   |-- init_db.py
|   |-- load_data.py
|   `-- .gitkeep
|-- sql/                 # SQL is the schema source of truth
|   |-- build_journeys.sql
|   |-- journeys.sql
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

Edit the local `.env` and replace the placeholder username, password, host, and port in `DATABASE_URL` with your local PostgreSQL settings. URL-encode special characters in credentials. `.env` and `.venv/` are ignored by Git; local credentials must stay out of version control. The helper loads `.env` relative to the repository root and preserves existing process environment variables. Plain `postgresql://` URLs select the installed Psycopg 3 driver; explicitly configured driver names are preserved.

PostgreSQL must already be running, the database must already exist, and `.env` must be configured. For a fresh database, follow this workflow:

```powershell
python scripts/init_db.py
python scripts/generate_data.py --seed 42
python scripts/load_data.py
python scripts/build_journeys.py --window-days 7
```

`init_db.py` executes `sql/schema.sql` in one transaction and is intended for a fresh, empty database. A repeat run fails on existing tables and rolls back. **Skip schema initialization if already done. Skip generation/loading if source data is already loaded**, and run only the journey builder. These commands are instructions for manual use and were not executed during this milestone.

## Synthetic data workflow

`generate_data.py` uses only the Python standard library and never opens a database connection. It writes one UTF-8 CSV per table under `data/generated/`, with the exact schema column names:

```text
users.csv          channels.csv       campaigns.csv
creatives.csv      impressions.csv    clicks.csv
conversions.csv    campaign_spend.csv user_revenue.csv
```

The default observation period is **2025-01-01 through 2025-03-31 inclusive**, in UTC (`2025-04-01T00:00:00+00:00` is the exclusive end). Defaults are 5,000 users, 5 channels, 10 campaigns, 30 creatives, exactly 50,000 impressions, approximately 5,000 clicks, approximately 1,000 conversions, and 900 daily spend rows. Revenue row counts vary with conversion activity and repeat purchases.

Click and conversion counts are sampled, not guaranteed. At most one initial conversion is generated per user; repeat transactions appear as revenue events. The generator starts every user with advertising exposure; signup dates are populated for converting users. Each campaign runs for the observation period. Clicks follow matching impressions by 1–30 minutes. Conversions follow the user's final simulated touch by 1–48 hours. Some impression-only conversions are possible.

Channel parameters are centralized in `CHANNEL_BEHAVIORS` and reflect educational assumptions:

| Channel | Synthetic behavior | Cost model |
| --- | --- | --- |
| Google Search | Medium volume; high click and conversion tendencies; later touches | Higher click costs |
| Meta | High volume; medium click and conversion tendencies | Impression and click costs |
| Programmatic Display | Highest volume; low direct response; earlier awareness | Low impression costs |
| Affiliate | Low volume; high click and conversion tendencies | Click costs |
| YouTube | Awareness volume; low clicks; modest boost to subsequent conversion likelihood | Impression costs |

Users have different interests and channel preferences, and exposure weights shift over their simulated activity periods. A designed cohort of up to 100 users has Display impression → Meta click → Google Search click → conversion sequences within a few days. These users receive no other touches. This ensures future attribution models can assign different campaign credit without implementing attribution now.

All money is exact `Decimal` in a single project-wide currency. Daily campaign spend equals that day's impression costs plus click costs; event costs must not be added to it again. Every converting user has an initial revenue receipt equal to the conversion value one minute after conversion. Some users have later receipts, with more repeats among higher-value users. The initial receipt and conversion value describe the same transaction and must not be summed together in future revenue analysis.

Configuration is centralized in `GeneratorConfig`. All random choices use a local `random.Random(seed)`. Dates, parent creation timestamps, row ordering, and CSV formatting are deterministic; the same code, configuration, and Python version produce identical CSVs. Rerunning generation **overwrites the nine CSVs**, but does not change PostgreSQL. It validates references, timestamp ranges/order, campaign/creative consistency, exact money, and daily spend before writing, then prints row counts and impression/click counts by channel.

Examples:

```powershell
python scripts/generate_data.py --seed 42
python scripts/generate_data.py --users 500 --impressions 5000 --clicks 500 --conversions 100
python scripts/generate_data.py --start-date 2025-01-01 --days 90
```

Use at least one impression per user, a click target no greater than impressions, a conversion target no greater than users, and a window of at least seven days. Larger response targets may fall short because probabilities are capped; prefer the small default settings.

`load_data.py` requires all nine CSVs and validates their headers, types, references, event timing, and spend consistency before connecting. It locks the project tables, refuses to load if **any project table already contains rows**, and inserts in dependency order: channels, users, campaigns, creatives, impressions, clicks, conversions, campaign spend, user revenue. All inserts use one transaction, in batches of 1,000 rows. Failures roll back the load.

CSV IDs are preserved using `OVERRIDING SYSTEM VALUE`, as the schema uses generated identity columns. Identity sequences are restarted above imported IDs within the same transaction. Use the database table owner (normally the account that initialized the schema), since restarting identities requires table ownership. No replacement flag, table dropping, or automatic clearing is implemented. Concurrent writes/loads cause the loader to wait at most five seconds for a lock before failing; individual SQL statements have a 60-second timeout. Generating new CSVs does not authorize overwriting existing database rows.

For future scripts in `scripts/`, use `from db import get_engine`, create `engine = get_engine()`, and manage connections with `with engine.connect() as connection:`. Call `engine.dispose()` when finished. Code imported from the repository root can use `from scripts.db import get_engine`. `get_connection()` is also available for a simple connection context. Importing the helper or calling `get_engine()` does not connect; opening a connection does.

## Conversion journeys

A conversion touchpoint is one original impression or click eligible for one conversion belonging to the same user. `sql/journeys.sql` defines the persistent `conversion_touchpoints` table. `sql/build_journeys.sql` inserts eligible impressions and clicks using `UNION ALL` and obtains channels from each event's campaign. The builder executes these files in PostgreSQL; it does not load the event dataset into Pandas or special-case the designed multi-touch users.

The seven-day default represents 168 elapsed hours. The exact eligibility rule is:

```text
conversion_time - window <= touchpoint_time < conversion_time
```

The lower boundary is included; the conversion timestamp and all later events are excluded. Both impressions and clicks are retained. Repeated events are kept as distinct source IDs; an impression and its subsequent click are separate touchpoints. Each conversion has an independent window, so one event may qualify for multiple conversions. This is candidate eligibility; future first-click, last-click, and linear models will select clicks according to the project specification. No weights, campaign credit, attributed conversions, or attributed revenue are assigned here.

Window precedence is `--window-days`, process `ATTRIBUTION_WINDOW_DAYS`, the root `.env`, then 7. Values must be positive integers that fit a PostgreSQL `INTEGER`. The script sets the transaction timezone to UTC. The chosen window is stored on every touchpoint so eligibility can be inspected even after configuration changes.

| Column | PostgreSQL type / meaning |
| --- | --- |
| `conversion_touchpoint_id` | `BIGINT`, generated identity primary key |
| `conversion_id` | `BIGINT`, foreign key to conversions |
| `user_id` | `BIGINT`, foreign key to users |
| `campaign_id` | `BIGINT`, foreign key to campaigns |
| `creative_id` | `BIGINT`, composite foreign key with campaign ID to creatives |
| `channel_id` | `BIGINT`, foreign key to channels |
| `impression_id` | Nullable `BIGINT`, foreign key to the source impression |
| `click_id` | Nullable `BIGINT`, foreign key to the source click |
| `touchpoint_type` | `TEXT`, only `impression` or `click` |
| `touchpoint_time` | `TIMESTAMPTZ`, source event timestamp |
| `conversion_time` | `TIMESTAMPTZ`, conversion timestamp |
| `seconds_before_conversion` | `NUMERIC(20, 6)`, exact nonnegative elapsed seconds |
| `attribution_window_days` | Positive `INTEGER`, build window |
| `created_at` | `TIMESTAMPTZ`, defaults to the build transaction time |

All columns except the two alternative source IDs are required. Exactly one source ID must match the touchpoint type. Foreign keys use restrictive deletes. Unique conversion/impression and conversion/click pairs prevent duplicate events within a conversion. Checks enforce the time boundaries and exact elapsed seconds. User, campaign, creative, channel, and conversion time are retained for understandable intermediate rows and future processing; the build joins supply them from the source relationships. Treat this as a derived snapshot and rebuild after changing source events/relationships or the window.

Indexes on `(conversion_id, touchpoint_time)` and `(user_id, touchpoint_time)` support chronological retrieval and user-history inspection. Primary-key and unique-pair constraints create their own supporting indexes. Use explicit ordering for retrieval. To resolve ties consistently without assigning attribution, order by `touchpoint_time`, then `touchpoint_type`, then `COALESCE(impression_id, click_id)`; reverse all three directions for reverse chronological order. This convention distinguishes tied events and expresses no causal preference.

The builder creates only the journey table and its indexes if absent; it does not rerun the base schema or migrate an existing incompatible journey table. A transaction advisory lock refuses overlapping builds, including first-time table creation. Source-table locks keep reads consistent, and the journey-table lock prevents concurrent writes. **A populated journey table causes refusal unless `--rebuild` is provided.** A rebuild deletes only `conversion_touchpoints` rows and inserts replacements in the same transaction; failures restore the previous rows. Source impressions, clicks, conversions, and other source tables are not altered. Identity IDs can have gaps and are not a chronology or a stable rebuild identifier; conversion/source-event pairs identify the relationship.

```powershell
python scripts/build_journeys.py --window-days 7
python scripts/build_journeys.py --window-days 7 --rebuild
```

Changing the window on an already populated table requires `--rebuild`. An empty result can be built again safely. Conversions without eligible events stay in `conversions`, have no touchpoint rows, and are included in the printed summary. The summary includes impression/click counts, conversions with/without touchpoints, and the average touchpoints across all conversions, without campaign analytics. The database role needs source-table read/lock access and permission to create/write the journey table. Lock waits are limited to five seconds and individual statements to 60 seconds.

Manual sanity queries (not executed during this milestone):

```sql
SELECT COUNT(*) FROM conversion_touchpoints;

SELECT * FROM conversion_touchpoints
ORDER BY conversion_id, touchpoint_time, touchpoint_type,
         COALESCE(impression_id, click_id)
LIMIT 50;

-- Expected: zero invalid eligibility/duration rows, using each row's build window.
SELECT COUNT(*) AS invalid_touchpoints
FROM conversion_touchpoints
WHERE touchpoint_time >= conversion_time
   OR touchpoint_time < conversion_time - attribution_window_days * INTERVAL '24 hours'
   OR seconds_before_conversion < 0
   OR seconds_before_conversion <> EXTRACT(EPOCH FROM (conversion_time - touchpoint_time));

-- Conversions that have no eligible impression or click.
SELECT c.conversion_id, c.user_id, c.conversion_time
FROM conversions AS c
WHERE NOT EXISTS (
    SELECT 1 FROM conversion_touchpoints AS t WHERE t.conversion_id = c.conversion_id
)
ORDER BY c.conversion_id
LIMIT 50;

-- Multi-channel examples, discovered from the data without hardcoded users/channels.
SELECT conversion_id, COUNT(DISTINCT channel_id) AS channel_count
FROM conversion_touchpoints
GROUP BY conversion_id
HAVING COUNT(DISTINCT channel_id) >= 3
ORDER BY conversion_id
LIMIT 20;
```

## Database foundation

The nine tables are `users`, `channels`, `campaigns`, `creatives`, `impressions`, `clicks`, `conversions`, `campaign_spend`, and `user_revenue`.

Channels own campaigns; campaigns own creatives. Impressions and clicks reference a user, campaign, and matching creative. Conversions and revenue reference users; daily spend references campaigns and is unique per campaign/date. All foreign keys use restrictive deletion to protect history. Conversions have no attributed campaign field.

Money uses nonnegative `NUMERIC(18, 6)` in one project-wide currency. Event timestamps use `TIMESTAMPTZ`. Signup dates can be absent before acquisition; campaign end dates can be absent for ongoing campaigns. Country values are intended as two-letter codes. Device and creative types remain text fields without separate type tables.

Initial indexes cover user/time lookups on impressions, clicks, conversions, and revenue, plus campaign/time lookups on impressions and clicks. Primary keys and unique constraints provide their own indexes, including campaign/date spend uniqueness. No materialized views or benchmarks exist yet.

Dependencies are deliberately unpinned in this initial scaffold. Version pinning can follow once the implementation is checked with Python 3.12.

**Validation for this milestone is limited to source/SQL inspection and lightweight Python syntax checks. Journey reconstruction and database writes were not executed. No tests, source regeneration/reloading, dependency installation, or benchmarks were run.**

## Planned milestones

1. **Completed: repository scaffold and project specification.**
2. **Implemented: PostgreSQL schema and local database configuration.** Successful initialization reported by the user.
3. **Implemented: synthetic CSV generator and safe PostgreSQL loader.** Source-data preparation is available for manual use.
4. **Implemented: user journey reconstruction and configurable eligibility.** Live journey execution/verification is pending.
5. **Next: first-click, last-click, and linear attribution using eligible clicks.**
6. Campaign metrics, simple LTV/cohort analysis, and model comparison.
7. One measured PostgreSQL query optimization using `EXPLAIN ANALYZE` before and after the change.
8. Metabase Campaign Overview, Attribution Model Comparison, and LTV / Cohort Analysis dashboards.
