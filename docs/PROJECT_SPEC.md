# Project Specification

## Status and authority

This document is the source of truth for future implementation of **Ad Campaign Attribution & ROI Analysis Engine**. PostgreSQL setup, synthetic generation/loading, journeys, and first-click/last-click/linear attribution are implemented. Attribution has been inspected but not executed against a live database during this milestone. Campaign/channel analytics, ROI/ROAS reporting, CAC/LTV, benchmarks, and dashboards remain unimplemented.

This is a local college-level analytics and data engineering project. The current milestone covers the three click-attribution models only; later pipeline stages require separate implementation requests.

## Core goal

Build a local advertising analytics system that:

1. Generates synthetic mobile advertising data.
2. Stores the data in PostgreSQL.
3. Reconstructs user advertising journeys before conversions.
4. Applies multiple attribution models.
5. Calculates campaign-performance metrics.
6. Calculates simple customer lifetime value metrics.
7. Compares attribution models.
8. Demonstrates one meaningful PostgreSQL query optimization.
9. Exposes the final analysis through Metabase.

## Planned pipeline and technologies

```text
Synthetic advertising events
    -> PostgreSQL
    -> User journey reconstruction
    -> First-click / Last-click / Linear attribution
    -> ROI / ROAS / CAC / LTV analysis
    -> Metabase
```

Use Python 3.12, PostgreSQL, SQLAlchemy, Pandas, Pytest, Metabase, and python-dotenv. The PostgreSQL driver in `requirements.txt` is Psycopg 3 (`psycopg[binary]`); the connection helper selects it for plain `postgresql://` URLs. Dependencies remain unpinned at this stage.

Do not introduce FastAPI, Flask, Django, AWS, Azure, GCP, Kafka, Redis, Airflow, Kubernetes, CI/CD pipelines, authentication, cloud deployment, microservices, frontend frameworks, or unnecessary abstractions.

## Advertising entities

The eventual database will represent:

- Users
- Channels
- Campaigns
- Creatives
- Impressions
- Clicks
- Conversions
- Campaign spend
- User revenue

The schema is defined in `sql/schema.sql`; SQL remains the primary source of schema definitions. `scripts/db.py` loads database configuration and exposes SQLAlchemy connection helpers. `scripts/init_db.py` initializes an existing empty database in one transaction without creating the database or dropping existing data.

Schema decisions: generated identity keys; `TIMESTAMPTZ` event timestamps; nonnegative `NUMERIC(18, 6)` monetary values in one project-wide currency; optional signup dates for users exposed before signup; optional campaign end dates; restrictive foreign-key deletes; composite event foreign keys enforcing creative/campaign consistency; and one spend row per campaign/date. Campaign spend will be the aggregate spending source for future metrics; event costs are supporting detail, not additional spend to sum on top. Conversion values and user revenue represent separate analytical records; their future overlap policy must be defined before revenue metrics are implemented.

## Attribution models and window

The following three models are implemented:

- **First-click:** assign credit to the first eligible click before a conversion.
- **Last-click:** assign credit to the last eligible click before a conversion.
- **Linear:** distribute credit equally across eligible clicks before a conversion.

Use a configurable attribution window with an initial default of **7 days**, recorded as `ATTRIBUTION_WINDOW_DAYS=7` in `.env.example`. `scripts/build_journeys.py` resolves a positive integer window from CLI, process environment, root `.env`, then the seven-day fallback. The window uses elapsed UTC days; eligibility is `conversion_time - window <= touchpoint_time < conversion_time` for the same user.

Do not add Markov, Shapley, machine learning, time-decay, or position-based attribution unless explicitly requested later. Journey eligibility retains both impressions and clicks, repeated source events, and independent windows for each conversion. Attribution uses eligible clicks only; no-click conversions receive no attribution rows and no impression fallback. First-click orders by touchpoint time and click ID ascending; last-click orders both descending. Linear assigns 1/N to every eligible click, including repeated clicks from one campaign.

`sql/journeys.sql` defines the persistent `conversion_touchpoints` intermediate table with source-event provenance, restrictive foreign keys, per-conversion event uniqueness, recorded window days, and exact elapsed seconds. Denormalized user/campaign/creative/channel IDs and conversion times improve readability; SQL joins supply consistent source values. `sql/build_journeys.sql` combines eligible event types using `UNION ALL` and derives channels from campaigns. The builder creates only this intermediate structure, refuses populated rows unless `--rebuild` is explicit, and transactionally replaces only journey rows when rebuilding. Source tables remain unchanged. No attribution weights or results are stored in the journey table.

`sql/attribution.sql` defines `attribution_results` at conversion/click/model granularity, with restrictive foreign keys, unique conversion/model/click pairs, and at most one first/last winner per conversion. Weights and allocated conversion values use `NUMERIC(38, 24)`; each value equals source conversion value multiplied by the stored weight, subject to negligible storage precision. `sql/run_attribution.sql` implements window-function ranking/counting. `sql/validate_attribution.sql` checks model coverage, cardinality, eligible-click mappings, weight totals within `1e-12`, and conversion-value totals within `1e-6` currency units. `scripts/run_attribution.py` creates the result structure, refuses populated results unless `--rebuild` is explicit, and transactionally inserts/validates all models. Only attribution rows are replaced during rebuild; source and journey rows are unchanged. Journeys must be current before attribution, and both snapshots must be rebuilt after source/window changes. No campaign/channel aggregation is implemented yet.

## Business metrics

The completed project will calculate:

- Impressions
- Clicks
- Conversions
- CTR
- CPC
- CPA
- Campaign spend
- Attributed conversions
- Attributed revenue
- ROAS
- ROI
- CAC
- Average user LTV
- LTV:CAC

Define metric denominators, revenue and cost assumptions, the observation period for simple LTV, and handling of zero denominators in the metrics milestone. Keep observed totals and attribution-derived metrics distinguishable when comparing models.

## Synthetic dataset

Generate data locally. Model meaningful differences in channel behavior rather than using completely uniform random data.

Initial planned channels:

- Google Search
- Meta
- Programmatic Display
- Affiliate
- YouTube

Begin with a small development dataset so local scripts are fast to run. A later dataset may contain approximately:

| Entity | Guideline count |
| --- | ---: |
| Users | 5,000 |
| Impressions | 50,000 |
| Clicks | 5,000 |
| Conversions | 1,000 |

These are guidelines, not hard constraints. `scripts/generate_data.py` now implements defaults of seed 42, 5,000 users, 50,000 impressions, approximately 5,000 clicks and 1,000 conversions, 10 campaigns, and 30 creatives. The fixed window is 2025-01-01 through 2025-03-31 inclusive in UTC. It produces nine schema-compatible CSVs, with channel-specific responses and a small designed multi-touch cohort. Daily spend reconciles to event costs. Initial revenue receipts equal conversion values for the same transaction; later receipts represent additional revenue, so initial receipts and conversion values must not be summed together. No generation was executed in this milestone.

`scripts/load_data.py` validates those CSVs, refuses populated project tables, serializes loads using table locks, and imports in one transaction without clearing data or recreating the schema. It preserves CSV IDs and transactionally advances existing identity sequences, requiring table ownership. Neither loading nor tests were executed. The next milestone begins after manual generation/loading.

## Database optimization requirement

Eventually demonstrate at least one real PostgreSQL optimization:

1. Run a meaningful analytics or cohort query.
2. Capture baseline performance with `EXPLAIN ANALYZE`.
3. Introduce suitable indexes and/or a materialized view.
4. Rerun the benchmark on comparable data and document the conditions.
5. Report the actual measured improvement, or honestly report no improvement.

Never fabricate a target improvement percentage. Benchmark execution belongs to the later optimization milestone and is prohibited during scaffolding.

## Visualization

Metabase will connect directly to PostgreSQL. Planned dashboards:

1. **Campaign Overview**
2. **Attribution Model Comparison**
3. **LTV / Cohort Analysis**

Do not implement Metabase configuration in the scaffolding milestone.

## Repository responsibilities

| Path | Intended contents |
| --- | --- |
| `data/raw/` | Raw input files |
| `data/generated/` | Locally generated synthetic datasets |
| `scripts/` | Database setup, synthetic generation/loading, journeys, and attribution |
| `sql/` | Schemas, journey/attribution SQL, and attribution validation; future analytics/optimization SQL |
| `notebooks/` | Future exploratory analysis |
| `tests/` | Future tests |
| `docs/PROJECT_SPEC.md` | Project scope and implementation constraints |
| `.env.example` | Placeholder configuration; no real credentials |
| `.gitignore` | Local environment, cache, and temporary file exclusions |
| `requirements.txt` | Minimal Python dependencies |
| `README.md` | Project overview, setup, status, and milestones |

## Scaffolding validation constraints

Validate this milestone only through lightweight inspection of files, directory structure, configuration, and source code. Confirm consistent paths, the required scope, and the absence of business logic and unnecessary components.

Do not run test suites or test commands, including `pytest`, `python -m pytest`, `unittest`, `tox`, `nox`, or `coverage`. Do not run automated validation frameworks, database benchmarks, large data generation, long-running processes, or computationally expensive commands. The presence of `tests/` and Pytest does not authorize test execution.

Do not create a real `.env`, initialize another Git repository, or commit anything during this milestone.

## Next recommended implementation milestone

**Campaign/channel performance reporting and model comparison:** after manually running and inspecting attribution, aggregate event counts, daily spend, attributed conversion credit, and allocated conversion values per model; define metric denominators and zero handling before implementing ROI/ROAS reporting. Defer CAC/LTV/cohort analysis, dashboards, and benchmarks. Do not begin this milestone automatically.
