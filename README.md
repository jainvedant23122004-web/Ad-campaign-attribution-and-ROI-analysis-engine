# Ad Campaign Attribution & ROI Analysis Engine

A college-level, local analytics and data engineering project for comparing mobile advertising attribution models and understanding campaign performance, return on investment, and customer lifetime value.

**Current status:** PostgreSQL setup, synthetic data, journeys, attribution, campaign/channel performance analytics, and observed LTV/CAC/acquisition cohorts are implemented. One PostgreSQL optimization experiment is complete: the cohort report was materialized, reconciled exactly, and measured with three paired EXPLAIN ANALYZE runs. Attribution was previously manually verified by the user. Metabase dashboards, budget optimization, and deployment remain unimplemented.

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
|-- scripts/             # Setup, data pipeline, attribution, and analytics setup
|   |-- benchmark_optimization.py
|   |-- build_journeys.py
|   |-- db.py
|   |-- generate_data.py
|   |-- init_db.py
|   |-- load_data.py
|   |-- run_attribution.py
|   |-- setup_analytics.py
|   |-- setup_ltv.py
|   `-- .gitkeep
|-- sql/                 # SQL is the schema source of truth
|   |-- analytics.sql
|   |-- analytics_checks.sql
|   |-- attribution.sql
|   |-- build_journeys.sql
|   |-- journeys.sql
|   |-- ltv_checks.sql
|   |-- ltv_cohorts.sql
|   |-- optimization.sql
|   |-- optimization_after.sql
|   |-- optimization_baseline.sql
|   |-- optimization_checks.sql
|   |-- run_attribution.sql
|   |-- schema.sql
|   |-- validate_attribution.sql
|   `-- .gitkeep
|-- notebooks/           # Future exploratory analysis
|   `-- .gitkeep
|-- tests/               # Future tests; none implemented or executed
|   `-- .gitkeep
|-- docs/
|   |-- OPTIMIZATION_RESULTS.md
|   |-- optimization_measurements.json
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
python scripts/run_attribution.py
python scripts/setup_analytics.py
python scripts/setup_ltv.py
```

`init_db.py` executes `sql/schema.sql` in one transaction and is intended for a fresh, empty database. A repeat run fails on existing tables and rolls back. **Skip completed schema/data/journey/attribution/analytics stages when their results are already current**, and run only the setup needed. During the LTV milestone only `setup_ltv.py` was executed; no earlier pipeline stage was rerun.

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

Users have different interests and channel preferences, and exposure weights shift over their simulated activity periods. A designed cohort of up to 100 users has Display impression → Meta click → Google Search click → conversion sequences within a few days. These users receive no other touches. The separate attribution stage can assign different campaign credit to these clicks without special-casing cohort users.

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

The lower boundary is included; the conversion timestamp and all later events are excluded. Both impressions and clicks are retained. Repeated events are kept as distinct source IDs; an impression and its subsequent click are separate touchpoints. Each conversion has an independent window, so one event may qualify for multiple conversions. Journey building records candidate eligibility; the separate attribution stage selects eligible clicks. Journey building itself assigns no weights, campaign credit, attributed conversions, or attributed revenue.

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

## Click attribution

`scripts/run_attribution.py` applies three models in PostgreSQL to `conversion_touchpoints` rows where `touchpoint_type = 'click'`. Impressions remain available for journey inspection and receive no attribution rows. A conversion with no eligible clicks stays unattributed under every model, with no impression fallback; the runner reports its count.

| Model | Policy | Deterministic ordering |
| --- | --- | --- |
| `first_click` | One earliest eligible click receives weight 1 and the full conversion value | `touchpoint_time ASC, click_id ASC` |
| `last_click` | One latest eligible click receives weight 1 and the full conversion value | `touchpoint_time DESC, click_id DESC` |
| `linear` | Each of N eligible clicks receives weight 1/N and value `conversion_value * weight` | Every eligible click is retained |

Repeated clicks from the same campaign are separate linear shares. Attribution results remain at **conversion + click + model** granularity; the separate analytics views aggregate them for campaigns/channels. For example, two eligible clicks from different campaigns yield full credit to different clicks under first/last click and half credit to each under linear. Actual results depend on the loaded journeys; no example results or counts are hardcoded.

`sql/attribution.sql` defines `attribution_results`:

| Column | PostgreSQL type / meaning |
| --- | --- |
| `attribution_result_id` | `BIGINT`, generated identity primary key |
| `conversion_id` | `BIGINT`, foreign key to conversions |
| `campaign_id` | `BIGINT`, foreign key to campaigns |
| `channel_id` | `BIGINT`, foreign key to channels |
| `creative_id` | `BIGINT`, composite foreign key with campaign ID to creatives |
| `click_id` | `BIGINT`, foreign key to the credited click |
| `attribution_model` | `TEXT`, only `first_click`, `last_click`, or `linear` |
| `attribution_weight` | `NUMERIC(38, 24)`, greater than zero and at most one |
| `attributed_conversion_value` | `NUMERIC(38, 24)`, nonnegative allocated value |
| `created_at` | `TIMESTAMPTZ`, defaults to transaction time |

Every column is required. Foreign keys use restrictive deletion. Unique `(conversion_id, attribution_model, click_id)` pairs prevent double credit; a partial unique index permits at most one first-click or last-click winner per conversion. Additional `(campaign_id, attribution_model)` and `(channel_id, attribution_model)` indexes support future summaries. The uniqueness index already supports conversion/model lookup, so no redundant standalone indexes are added.

`sql/run_attribution.sql` uses `ROW_NUMBER()` for earliest/latest selection and `COUNT(*) OVER (PARTITION BY conversion_id)` for linear shares. Decimal division starts with 24 decimal places; values are allocated from stored weights. There is no cent rounding or residual assignment to a favored click. Recurring fractions may differ negligibly from exact conservation because of finite numeric precision.

`sql/validate_attribution.sql` runs **inside the transaction before commit**. It requires all three model groups for every conversion with eligible clicks, one first/last row, one linear row per eligible click, and matching eligible click/campaign/channel/creative relationships. Each conversion/model must satisfy:

```text
abs(sum(weights) - 1) <= 0.000000000001
abs(sum(allocated conversion values) - conversion_value) <= 0.000001
```

These are absolute numeric tolerances: one trillionth of credit and one millionth of a currency unit. Violations fail clearly and roll back all changes. The success summary prints actual conversion/model row counts and confirms weight/value validation, including zero-row models when no conversions have eligible clicks.

With the base schema, source data, and current journeys already available, run manually:

```powershell
python scripts/run_attribution.py
```

The runner creates only the attribution table/indexes if absent and refuses populated results by default. To replace only attribution results:

```powershell
python scripts/run_attribution.py --rebuild
```

Creation, optional deletion, insertion, and validation share one transaction. A failed rebuild restores previous attribution rows. Advisory and table locks protect overlapping executions and keep source/journey reads consistent. Source events and journey rows are not modified. Use the database role with source/journey read/lock access and permission to create/write the result table; lock waits are limited to five seconds and individual statements to 60 seconds.

Attribution consumes the existing journey window; it does not read a new window from `.env` or rebuild journeys automatically. After changing the window or source events, rebuild journeys first and then attribution with explicit `--rebuild` flags. Attribution rows intentionally have no foreign key to intermediate journey rows, permitting this sequence. The runner rejects existing eligible-click rows whose source mappings or timestamps have changed, but does not detect newly added events absent from a stale snapshot; keeping journeys current remains part of the workflow.

Manual sanity queries (not executed during this milestone):

```sql
SELECT attribution_model, COUNT(*)
FROM attribution_results
GROUP BY attribution_model
ORDER BY attribution_model;

-- Expected: zero rows; the runner uses the same strict weight tolerance.
SELECT conversion_id, attribution_model,
       SUM(attribution_weight) AS total_weight
FROM attribution_results
GROUP BY conversion_id, attribution_model
HAVING ABS(SUM(attribution_weight) - 1) > 0.000000000001;

-- Expected: zero rows.
SELECT r.conversion_id, r.attribution_model,
       SUM(r.attributed_conversion_value) AS total_value, c.conversion_value
FROM attribution_results AS r
JOIN conversions AS c ON c.conversion_id = r.conversion_id
GROUP BY r.conversion_id, r.attribution_model, c.conversion_value
HAVING ABS(SUM(r.attributed_conversion_value) - c.conversion_value) > 0.000001;

-- Discover a multi-click conversion and show every click under every model.
-- Missing first/last result rows are displayed as zero credit for inspection only.
WITH example AS (
    SELECT conversion_id
    FROM conversion_touchpoints
    WHERE touchpoint_type = 'click'
    GROUP BY conversion_id
    HAVING COUNT(*) >= 2 AND COUNT(DISTINCT campaign_id) >= 2
    ORDER BY conversion_id
    LIMIT 1
), models (attribution_model) AS (
    VALUES ('first_click'), ('last_click'), ('linear')
)
SELECT c.conversion_id, c.conversion_value, m.attribution_model,
       t.click_id, t.touchpoint_time, ca.campaign_name, ch.channel_name,
       COALESCE(r.attribution_weight, 0) AS weight,
       COALESCE(r.attributed_conversion_value, 0) AS allocated_value
FROM example AS e
JOIN conversions AS c ON c.conversion_id = e.conversion_id
JOIN conversion_touchpoints AS t ON t.conversion_id = c.conversion_id
CROSS JOIN models AS m
JOIN campaigns AS ca ON ca.campaign_id = t.campaign_id
JOIN channels AS ch ON ch.channel_id = ca.channel_id
LEFT JOIN attribution_results AS r
    ON r.conversion_id = c.conversion_id AND r.click_id = t.click_id
    AND r.attribution_model = m.attribution_model
WHERE t.touchpoint_type = 'click'
ORDER BY m.attribution_model, t.touchpoint_time, t.click_id;
```

## Campaign/channel analytics

With source data, current journeys, and attribution results already available, create or replace the analytics views:

```powershell
python scripts/setup_analytics.py
```

The script applies `sql/analytics.sql` transactionally in dependency order. Rerunning setup is safe for these same view definitions. It does not regenerate data, rebuild journeys, run attribution, or write to source/result tables. The database role needs schema creation/view ownership and read access to the underlying tables. A failed setup rolls back view changes; lock waits are limited to five seconds and individual statements to 30 seconds.

These are ordinary views over **all currently loaded data**, without a date filter or rounding. Their values reflect the current source/attribution tables when queried; there are no materialized views or refresh jobs. Keep attribution current after source/window changes using the earlier explicit rebuild workflow.

| View | Grain | Columns |
| --- | --- | --- |
| `campaign_performance` | One row per campaign/model | `campaign_id`, `campaign_name`, `channel_id`, `channel_name`, `attribution_model`, `impressions`, `clicks`, `ctr`, `spend`, `raw_conversions`, `attributed_conversions`, `attributed_revenue`, `cpc`, `cpa`, `roas`, `roi` |
| `channel_performance` | One row per channel/model | Same metrics and channel/model identifiers, without campaign ID/name |
| `attribution_model_comparison` | One row per channel/model, long format | `channel_id`, `channel_name`, `attribution_model`, `attributed_conversions`, `attributed_revenue`, `roas`, `roi` |

| Metric | Definition | Zero-denominator handling |
| --- | --- | --- |
| Impressions / clicks | Counts of their source events | Missing activity is zero |
| Spend | Sum of `campaign_spend.spend` | Missing spend is zero |
| CTR | Clicks / impressions | `NULL` with zero impressions |
| CPC | Spend / clicks | `NULL` with zero clicks |
| Attributed conversions | Sum of `attribution_results.attribution_weight` | No credit is zero |
| Attributed revenue | Sum of `attribution_results.attributed_conversion_value` | No allocated value is zero |
| CPA | Spend / attributed conversions | `NULL` with zero attributed conversions |
| ROAS | Attributed revenue / spend | `NULL` with zero spend |
| ROI | (Attributed revenue - spend) / spend | `NULL` with zero spend |

CTR and ROI are **decimal ratios**, not percentages; ROAS is a revenue/spend multiple. Division uses exact PostgreSQL numeric arithmetic and `NULLIF`, with no artificial zero ratios or presentation rounding. Positive spend with zero attributed revenue yields ROAS 0 and ROI -1. Zero attribution yields CPA `NULL`. No `user_revenue` receipts are included in ROAS, and impression/click costs are not added again to official spend.

`raw_conversions` is a **model-independent count of distinct conversions with an eligible click from that campaign/channel**. It measures association, not exclusive ownership or allocated credit. One conversion can appear under several campaigns/channels, so these counts are not additive. Channel raw counts are deduplicated directly from click journeys, rather than summed from campaigns. Campaign conversion reporting should primarily use fractional attributed conversions.

Impressions, clicks, spend, journey associations, and attribution are each aggregated separately before their one-row totals are joined. Campaigns are crossed with the three model names, then left-joined to totals, preserving zero-credit and inactive campaigns. Channels are similarly anchored to every channel/model combination, including channels with no campaigns. Channel additive totals are summed within each model, and CTR/CPC/CPA/ROAS/ROI are recomputed from those totals, never averaged from campaign ratios.

Spend, impressions, clicks, CTR, CPC, and raw associations are repeated across the three model rows; **filter or group by `attribution_model` before summing**, to avoid triple-counting these baseline metrics. Models redistribute conversion credit/value, not spend or the total attributable revenue. Revenue reconciliation uses conversion value only for conversions with eligible clicks, counting each conversion once with `EXISTS`; no-click conversion values are excluded.

`sql/analytics_checks.sql` contains manual read-only inspection and reconciliation queries. They compare per-model campaign/channel totals with official source spend/event counts and attribution totals, then reconcile attribution revenue/credit to eligible-click conversions. Expected reconciliation flags are true; decimal tolerances are `1e-12` for credit and `1e-6` for conversion value. Existing per-conversion/model weight validation remains in the Click attribution section and `sql/validate_attribution.sql`.

Example inspection queries:

```sql
SELECT * FROM channel_performance
ORDER BY attribution_model, roas DESC NULLS LAST;

SELECT * FROM campaign_performance
ORDER BY attribution_model, roas DESC NULLS LAST
LIMIT 30;

SELECT channel_name, attribution_model, attributed_revenue, spend, roas
FROM channel_performance
ORDER BY channel_name, attribution_model;

-- Channels whose allocated conversion revenue differs most between models.
SELECT channel_name,
       MAX(attributed_revenue) - MIN(attributed_revenue) AS revenue_range
FROM attribution_model_comparison
GROUP BY channel_id, channel_name
ORDER BY revenue_range DESC
LIMIT 10;

-- Each model's spend must equal SUM(campaign_spend.spend).
SELECT attribution_model, SUM(spend) AS analytics_spend,
       (SELECT SUM(spend) FROM campaign_spend) AS official_spend
FROM campaign_performance
GROUP BY attribution_model
ORDER BY attribution_model;
```

Live inspection during the performance-analytics milestone found 30 campaign/model rows, 15 channel/model rows, and 15 comparison rows. Each model reconciled to 898 attributable conversions and 91,558.57 conversion value within the documented tolerances. Official spend was exactly 3,981.894834 under every model in both performance views, and impression/click totals reconciled. These are observed synthetic-data results, not constants in the views. The current dataset had no positive-spend/zero-credit campaign rows; that edge behavior was reviewed in SQL rather than demonstrated by altering data.

## Observed LTV, CAC, and acquisition cohorts

With existing source data and current attribution results, run from the repository root:

```powershell
python scripts/setup_ltv.py
```

Without activating the existing virtual environment, use `.\.venv\Scripts\python.exe scripts/setup_ltv.py`. The script uses the existing database helper and applies `sql/ltv_cohorts.sql` in dependency order in one transaction. It creates/replaces only five ordinary views. Reapplying these definitions is safe; failures roll back view changes. A setup advisory lock refuses overlapping LTV setups, lock waits are limited to five seconds, and statements to 30 seconds. The database role needs read access to source/attribution tables and schema creation/view ownership permissions. The views reflect all currently loaded data on each query and require no refresh.

**Acquisition source** is the campaign/channel receiving `first_click` attribution for a user's earliest attributable conversion, ordered by conversion timestamp, conversion ID, then click ID. Acquisition time is that conversion's timestamp, not the credited click time or signup date. Earlier unattributed conversions do not assign a source; users without any first-click-attributable conversion are excluded. One user has at most one source, which is never assigned from impressions, last-click, or linear results.

**Observed LTV** is `SUM(user_revenue.revenue_amount)` across all loaded receipts for each acquired user. Missing receipts yield zero LTV and zero revenue events; these users remain in averages and medians. It measures the finite dataset window and does not predict future revenue. All-receipt LTV would include any receipt before the earliest attributable conversion; the cohort windows explicitly exclude such receipts, and the manual checks report their count. No such receipts were found in the current data.

**CAC** is official campaign/channel `SUM(campaign_spend.spend) / acquired_users`, using distinct acquired users rather than conversion credits. **LTV:CAC** is `average_ltv / cac`. Zero acquired users yield CAC `NULL`; zero or missing CAC yields ratio `NULL`. Spend covers the full loaded period, including spend that acquired no attributable users. This is a descriptive comparison of the observed dataset, without a hardcoded marketing benchmark or causal claim.

Campaigns/channels with no acquisitions still appear: users and lifetime revenue are zero, average/median LTV are `NULL`, and official spend is retained. Spend is aggregated independently before joining user totals, avoiding multiplication. Channel statistics are computed directly from channel users, not campaign averages. Median uses the exact numeric middle value for odd populations or the mean of the two middle values for even populations, equivalent to `PERCENTILE_CONT(0.5)` without converting money to floating point. Results are not rounded.

| View | Grain | Exact columns |
| --- | --- | --- |
| `user_acquisition` | One row per acquired user | `user_id`, `first_conversion_id`, `acquisition_campaign_id`, `acquisition_campaign_name`, `acquisition_channel_id`, `acquisition_channel_name`, `acquisition_time` |
| `user_ltv` | One row per acquired user | `user_id`, `acquisition_campaign_id`, `acquisition_channel_id`, `acquisition_time`, `lifetime_revenue`, `revenue_event_count` |
| `campaign_ltv` | One row per campaign | `campaign_id`, `campaign_name`, `channel_id`, `channel_name`, `acquired_users`, `total_lifetime_revenue`, `average_ltv`, `median_ltv`, `spend`, `cac`, `ltv_cac_ratio` |
| `channel_ltv` | One row per channel | `channel_id`, `channel_name`, `acquired_users`, `total_lifetime_revenue`, `average_ltv`, `median_ltv`, `spend`, `cac`, `ltv_cac_ratio` |
| `acquisition_cohort_ltv` | UTC acquisition month + channel | `acquisition_month`, `channel_id`, `channel_name`, `acquired_users`, `observation_end`, `eligible_users_d7`, `eligible_users_d30`, `eligible_users_d60`, `eligible_users_d90`, `revenue_d7`, `revenue_d30`, `revenue_d60`, `revenue_d90`, `average_ltv_d7`, `average_ltv_d30`, `average_ltv_d60`, `average_ltv_d90` |

An **acquisition cohort** groups users by UTC month of acquisition and acquisition channel. D7/D30/D60/D90 are cumulative receipts in `[acquisition_time, acquisition_time + N * 24 hours)`, including acquisition-time revenue and excluding revenue before acquisition or exactly at the upper boundary. Elapsed hours avoid session-timezone/DST changes. Each horizon sums only users whose complete horizon ends on or before the dataset's exclusive observation end. Its average divides by that horizon's eligible-user count, including eligible users with zero revenue. Late users remain in `acquired_users` and any shorter mature horizons. If nobody is eligible, both revenue and average are `NULL`, not fabricated zeros.

The observation end is midnight UTC after `MAX(campaign_spend.spend_date)`. This relies on the synthetic generator's **complete daily spend ledger, including zero-spend days**, covering the same observation period as events and receipts. Do not interpret horizons from a sparse/incomplete ledger without first establishing coverage. An empty ledger gives no mature values. The cutoff is not today's date or the latest receipt timestamp, because neither proves observed follow-up coverage. The current cutoff is `2025-04-01 00:00:00+00`.

Horizon eligibility populations can differ, so published cohort averages/totals need not increase across horizons. Monotonicity must compare the **same users**: `sql/ltv_checks.sql` compares D7/D30 for D30-mature users, D30/D60 for D60-mature users, and D60/D90 for D90-mature users, grouped by cohort. Each pair should be nondecreasing with zero decreasing users. No row is returned for an empty common population. These cohorts describe monetization; they do not estimate activity retention from revenue alone.

Keep conversion-based ROAS/ROI and LTV separate. Performance views use `attributed_conversion_value`; LTV uses only `user_revenue`. Initial receipts represent the same transaction as initial conversion value, so never add them together. Later receipts contribute to LTV without being attributed again as conversion revenue.

Manual read-only queries in `sql/ltv_checks.sql` cover acquisition uniqueness/policy/population, nonnegative LTV, acquired-source revenue/event reconciliation, excluded revenue, campaign/channel totals and official spend, observation coverage, cohort eligibility/averages, and cumulative monotonicity on common populations. Run them with a short timeout, for example:

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '15s';
-- Execute sql/ltv_checks.sql here in your SQL client.
COMMIT;
```

Live inspection found 898 acquisition/user-LTV rows, 10 campaign rows, 5 channel rows, and 15 month/channel cohorts. Acquired users' 1,547 receipts reconciled exactly to **173,423.742800** observed LTV. Source receipts totaled **201,104.298900**; **27,680.556100** from 121 non-acquired revenue users was explicitly excluded. Both aggregate levels reconciled to 898 users, acquired revenue, and **3,981.894834** official spend. Acquisition duplicates, invalid mappings, negative/missing LTV, inconsistent cohort rows, pre-acquisition receipts, and receipts after the cutoff were all zero. All populated common-horizon monotonicity checks passed.

| UTC acquisition month | Acquired users | D7 eligible | D30 eligible | D60 eligible | D90 eligible |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2025-01 | 225 | 225 | 225 | 221 | 0 |
| 2025-02 | 286 | 286 | 286 | 0 | 0 |
| 2025-03 | 387 | 258 | 9 | 0 | 0 |

No current user has a full 90-day follow-up after acquisition; all D90 values are therefore `NULL`, and D90 monotonicity could not be demonstrated on this dataset. These are live observations, not hardcoded view results. Missing-receipt and zero-denominator behavior was inspected in SQL without inserting artificial data.

Useful inspection queries:

```sql
SELECT * FROM channel_ltv ORDER BY average_ltv DESC NULLS LAST;

SELECT channel_name, acquired_users, average_ltv, cac, ltv_cac_ratio
FROM channel_ltv ORDER BY ltv_cac_ratio DESC NULLS LAST;

SELECT * FROM campaign_ltv ORDER BY ltv_cac_ratio DESC NULLS LAST;

SELECT * FROM acquisition_cohort_ltv ORDER BY acquisition_month, channel_name;
```

## Measured PostgreSQL cohort optimization

The existing acquisition-month/channel D7/D30/D60/D90 report was optimized using one `acquisition_cohort_materialized` snapshot. Its live plan recomputed acquisition ranking, performed 898 indexed revenue lookups, and aggregated users into 15 cohort rows. The stored report instead scans and sorts those 15 rows. Existing user/revenue-time and attribution indexes were inspected; no extra indexes were added.

Three alternating baseline/optimized pairs, after exact reconciliation warmed both reports, produced these PostgreSQL execution times: baseline **5.795 / 9.732 / 6.063 ms**, optimized **0.030 / 0.037 / 0.185 ms**. Median execution fell from **6.063 ms** to **0.037 ms**, a measured reduction of **99.389741%**, or **6.026 ms**. This measures warm report reads on the current small dataset, excluding materialization/refresh cost; it is not an application-wide performance claim. Both directions of `EXCEPT ALL` returned zero differences across all 15 rows. Full methodology, planning times, plans, and limitations are in [docs/OPTIMIZATION_RESULTS.md](docs/OPTIMIZATION_RESULTS.md) and [docs/optimization_measurements.json](docs/optimization_measurements.json).

Run this single scoped experiment from the root using the existing environment:

```powershell
python scripts/benchmark_optimization.py --setup
```

`--setup` creates the materialized view if absent and refreshes it; setup commits before read-only measurement. The script then refuses mismatched/stale results and measures exactly three alternating pairs in one REPEATABLE READ snapshot. Omit `--setup` to measure an already-current snapshot. Optional `--output docs/optimization_measurements_rerun.json` saves a new record with all six plans. Without activation, use `.\.venv\Scripts\python.exe`. SQL query, setup, and reconciliation definitions are in `sql/optimization_baseline.sql`, `sql/optimization_after.sql`, `sql/optimization.sql`, and `sql/optimization_checks.sql`.

The original live cohort/LTV views retain their existing behavior. The optimized report is explicitly read from `acquisition_cohort_materialized`; it requires manual refresh after relevant source/attribution/cohort changes:

```sql
REFRESH MATERIALIZED VIEW acquisition_cohort_materialized;
```

There is no refresh job. Ordinary refresh blocks materialized-view readers and recomputes the full report. The initial create/populate call took **63.317 ms client elapsed**, separately from report execution. The snapshot can become stale, and this small experiment does not establish production scalability or a need to replace the already-fast live view.

## Database foundation

The nine tables are `users`, `channels`, `campaigns`, `creatives`, `impressions`, `clicks`, `conversions`, `campaign_spend`, and `user_revenue`.

Channels own campaigns; campaigns own creatives. Impressions and clicks reference a user, campaign, and matching creative. Conversions and revenue reference users; daily spend references campaigns and is unique per campaign/date. All foreign keys use restrictive deletion to protect history. Conversions have no attributed campaign field.

Money uses nonnegative `NUMERIC(18, 6)` in one project-wide currency. Event timestamps use `TIMESTAMPTZ`. Signup dates can be absent before acquisition; campaign end dates can be absent for ongoing campaigns. Country values are intended as two-letter codes. Device and creative types remain text fields without separate type tables.

Initial indexes cover user/time lookups on impressions, clicks, conversions, and revenue, plus campaign/time lookups on impressions and clicks. Primary keys and unique constraints provide their own indexes, including campaign/date spend uniqueness. The optimization milestone adds only the cohort materialization described above; no new indexes or unrelated materialized reports were added.

Dependencies are deliberately unpinned in this initial scaffold. Version pinning can follow once the implementation is checked with Python 3.12.

**Validation used source/syntax and live view/index inspection, exact read-only reconciliation, one diagnostic EXPLAIN ANALYZE, and six scoped measured EXPLAIN ANALYZE statements. No source/journey/attribution rows were modified. No tests, data regeneration/reloading, journey/attribution rebuilds, dependency installation, unrelated benchmarks, or stress tests were run.**

## Planned milestones

1. **Completed: repository scaffold and project specification.**
2. **Implemented: PostgreSQL schema and local database configuration.** Successful initialization reported by the user.
3. **Implemented: synthetic CSV generator and safe PostgreSQL loader.** Source-data preparation is available for manual use.
4. **Implemented: user journey reconstruction and configurable eligibility.** Existing journey rows were used by the analytics inspection; the builder was not rerun.
5. **Implemented: first-click, last-click, and linear attribution using eligible clicks.** Manual verification reported successful by the user.
6. **Implemented and inspected live: campaign/channel performance analytics and model comparison.**
7. **Implemented and inspected live: observed user/campaign/channel LTV, CAC/LTV:CAC, and acquisition-month/channel revenue cohorts with horizon eligibility.**
8. **Completed: one measured PostgreSQL cohort-report optimization**, with exact equivalence and actual before/after timings documented.
9. **Next: Metabase** Campaign Overview, Attribution Model Comparison, and LTV / Cohort Analysis dashboards, only in a separately requested milestone.
