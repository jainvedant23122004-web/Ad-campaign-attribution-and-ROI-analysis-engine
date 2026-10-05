# Project Specification

## Status and authority

This document is the source of truth for future implementation of **Ad Campaign Attribution & ROI Analysis Engine**. PostgreSQL setup, synthetic data, journeys, attribution, campaign/channel performance analytics, and observed LTV/CAC/acquisition cohorts are implemented. One real PostgreSQL cohort-report optimization is complete, using an isolated materialized view, exact reconciliation, and three paired EXPLAIN ANALYZE measurements. Attribution had already been manually verified by the user. Metabase dashboards, budget optimization, and deployment remain unimplemented.

This is a local college-level analytics and data engineering project. The current milestone covers one measured PostgreSQL optimization only; dashboards and later stages require separate implementation requests.

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

`sql/attribution.sql` defines `attribution_results` at conversion/click/model granularity, with restrictive foreign keys, unique conversion/model/click pairs, and at most one first/last winner per conversion. Weights and allocated conversion values use `NUMERIC(38, 24)`; each value equals source conversion value multiplied by the stored weight, subject to negligible storage precision. `sql/run_attribution.sql` implements window-function ranking/counting. `sql/validate_attribution.sql` checks model coverage, cardinality, eligible-click mappings, weight totals within `1e-12`, and conversion-value totals within `1e-6` currency units. `scripts/run_attribution.py` creates the result structure, refuses populated results unless `--rebuild` is explicit, and transactionally inserts/validates all models. Only attribution rows are replaced during rebuild; source and journey rows are unchanged. Journeys must be current before attribution, and both snapshots must be rebuilt after source/window changes. The separate analytics layer consumes these results without recomputing attribution.

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

`sql/analytics.sql` implements ordinary `campaign_performance`, `channel_performance`, and long-format `attribution_model_comparison` views over all loaded data. Event counts, official `campaign_spend`, and attribution credit/value are independently aggregated to prevent join multiplication. Every campaign/channel appears under all three models. Channel ratios are computed from additive totals, not campaign-ratio averages. CTR = clicks/impressions; CPC = spend/clicks; attributed conversions = sum of weights; attributed revenue = sum of allocated conversion values; CPA = spend/attributed conversions; ROAS = attributed revenue/spend; ROI = (attributed revenue - spend)/spend. CTR/ROI are decimal ratios; zero denominators return NULL, and positive spend with zero revenue gives ROAS 0 and ROI -1. `raw_conversions` counts distinct conversions with eligible clicks from the entity and is nonexclusive/nonadditive. No user revenue or lifetime metrics are mixed into ROAS.

`scripts/setup_analytics.py` transactionally creates/replaces only these views. `sql/analytics_checks.sql` supplies read-only revenue/credit, spend, and event-count reconciliation against source totals; these checks were inspected successfully against the live dataset. Spend stays unchanged per model; all models redistribute the same eligible-click conversion value. Keep observed totals and attribution-derived metrics distinguishable, and never sum repeated baseline spend across models.

## Implemented observed LTV/CAC and acquisition cohorts

`sql/ltv_cohorts.sql` defines ordinary `user_acquisition`, `user_ltv`, `campaign_ltv`, `channel_ltv`, and `acquisition_cohort_ltv` views. `scripts/setup_ltv.py` creates/replaces them in one transaction using the existing database helper, an overlapping-setup advisory lock, and bounded lock/statement waits. It changes no source, journey, or attribution rows.

Acquisition is the first-click campaign/channel for each user's earliest attributable conversion, ordered by conversion timestamp, conversion ID, and click ID; acquisition time is the conversion timestamp. Users without such a conversion have no source and are excluded. Observed LTV sums all existing `user_revenue.revenue_amount` for acquired users, preserving zero-receipt users. Cohorts exclude pre-acquisition receipts. Initial receipts and conversion values represent the same transaction and must never be added together; conversion-value ROAS/ROI remains separate. No lifetime prediction is made.

Campaign/channel statistics aggregate user LTV directly, with an exact numeric midpoint median and separately aggregated official spend. CAC = full loaded spend / acquired users, with NULL for zero users; LTV:CAC = average LTV / CAC, with NULL for zero/missing CAC. All campaigns/channels appear, including those with no acquisitions. Zero-user averages/medians are NULL. Channel averages are not averages of campaign averages.

Cohorts group by UTC acquisition month and acquisition channel. D7/D30/D60/D90 use cumulative revenue in the half-open interval from acquisition through N elapsed 24-hour days. Each horizon includes only users with full observable follow-up and exposes its eligible-user count. Late users remain in cohort population counts; an empty eligible population has NULL revenue/average. The exclusive cutoff is midnight UTC after the last spend date, relying on the generator's complete daily ledger, including zero-spend dates. Neither the last receipt nor today's date proves observation coverage. Empty coverage gives no mature values. Horizon populations differ, so cumulative monotonicity checks must hold the eligible population constant. These are revenue/monetization cohorts, not behavioral retention estimates.

`sql/ltv_checks.sql` supplies lightweight read-only acquisition, revenue, spend, coverage, cohort consistency, and common-population monotonicity queries. Live inspection found 898 acquired users with 1,547 receipts and 173,423.742800 LTV, exactly reconciling to acquired source receipts. Revenue of 27,680.556100 from 121 non-acquired revenue users is excluded, not forced into acquisition metrics. Both campaign/channel totals reconcile to 3,981.894834 official spend. Fifteen month/channel cohort rows use an exclusive cutoff of 2025-04-01 00:00 UTC; none has D90-mature users, so D90 values are NULL and D90 monotonicity lacks a live population. Other populated common-horizon checks passed, with zero acquisition duplicates, invalid mappings, negative/missing LTV, or inconsistent cohort rows. No source writes, pipeline reruns, tests, dependency installs, or benchmarks were performed. Exact columns, commands, methodology, and queries are documented in README.

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

`scripts/load_data.py` validates those CSVs, refuses populated project tables, serializes loads using table locks, and imports in one transaction without clearing data or recreating the schema. It preserves CSV IDs and transactionally advances existing identity sequences, requiring table ownership. Source generation/loading remain explicit manual steps and were not rerun during the analytics milestone.

## Database optimization requirement

Demonstrate at least one real PostgreSQL optimization:

1. Run a meaningful analytics or cohort query.
2. Capture baseline performance with `EXPLAIN ANALYZE`.
3. Introduce suitable indexes and/or a materialized view.
4. Rerun the benchmark on comparable data and document the conditions.
5. Report the actual measured improvement, or honestly report no improvement.

Never fabricate a target improvement percentage. The explicitly requested optimization milestone permits only the chosen report's small fixed measurement; broad benchmarks and stress tests remain prohibited.

Completed experiment: `sql/optimization_baseline.sql` measures the existing acquisition-month/channel cumulative revenue report; `sql/optimization.sql` creates/refreshes only `acquisition_cohort_materialized`; `sql/optimization_after.sql` reads that equivalent snapshot. No new indexes were needed because user/revenue-time and attribution indexes already exist. The baseline plan's acquisition ranking, 898 indexed revenue lookups, and user/cohort aggregation become a scan/sort of 15 stored rows. `sql/optimization_checks.sql` uses exact bidirectional EXCEPT ALL; both results had 15 rows and zero differences. `scripts/benchmark_optimization.py` performs reconciliation warm-up and three alternating pairs in one read-only REPEATABLE READ transaction, with bounded waits and no planner/cache manipulation. Median PostgreSQL execution fell from 6.063 ms to 0.037 ms, a 99.389741% reduction in warm report-read latency. All individual execution/planning timings and six plans are recorded in `docs/OPTIMIZATION_RESULTS.md` and `docs/optimization_measurements.json`. Manual refresh is required; refresh/setup cost is excluded from that percentage, and the small dataset does not establish scalability. No source writes, pipeline reruns, tests, dependency installs, or unrelated benchmarks were performed.

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
| `scripts/` | Database setup, synthetic generation/loading, journeys, attribution, and analytics setup |
| `sql/` | Schemas, journey/attribution SQL, analytics views, reconciliation, and isolated cohort optimization SQL |
| `notebooks/` | Future exploratory analysis |
| `tests/` | Future tests |
| `docs/PROJECT_SPEC.md` | Project scope and implementation constraints |
| `.env.example` | Placeholder configuration; no real credentials |
| `.gitignore` | Local environment, cache, and temporary file exclusions |
| `requirements.txt` | Minimal Python dependencies |
| `README.md` | Project overview, setup, status, and milestones |

## Scaffolding validation constraints

Validate the scaffolding milestone only through lightweight inspection of files, directory structure, configuration, and source code. Confirm consistent paths, the required scope, and the absence of business logic and unnecessary components.

Do not run test suites or test commands, including `pytest`, `python -m pytest`, `unittest`, `tox`, `nox`, or `coverage`. Do not run automated validation frameworks, broad database benchmarks, large data generation, long-running processes, or computationally expensive commands. The explicitly requested, scoped EXPLAIN ANALYZE experiment above is the optimization-milestone exception. The presence of `tests/` and Pytest does not authorize test execution.

Do not create a real `.env`, initialize another Git repository, or commit anything during this milestone.

## Next recommended implementation milestone

**Metabase dashboards:** connect the existing local PostgreSQL analytics and design Campaign Overview, Attribution Model Comparison, and LTV / Cohort Analysis dashboards in a separately requested milestone. Account for materialized-cohort freshness when choosing report sources. Metabase, budget optimization, deployment, cloud infrastructure, and CI/CD are not implemented; do not begin them automatically. The prohibition on tests and broad/expensive benchmarks remains in effect.
