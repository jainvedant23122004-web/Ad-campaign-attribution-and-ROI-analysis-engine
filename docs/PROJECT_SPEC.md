# Project Specification

## Status and authority

This document is the source of truth for future implementation of **Ad Campaign Attribution & ROI Analysis Engine**. The repository currently contains only directories, dependency declarations, a configuration template, and documentation. No database schema, business logic, data generator, analytics queries, benchmarks, or dashboards are implemented.

This is a local college-level analytics and data engineering project. The current milestone is scaffolding only; implementation begins in a separately requested milestone.

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

Use Python 3.12, PostgreSQL, SQLAlchemy, Pandas, Pytest, Metabase, and python-dotenv. The PostgreSQL driver in `requirements.txt` is psycopg2-binary, compatible with the template's `postgresql://` SQLAlchemy URL. Dependencies remain unpinned at this stage.

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

The full SQL schema, relationships, data types, and constraints will be defined in the database milestone, not during scaffolding.

## Attribution models and window

Implement only these models:

- **First-click:** assign credit to the first eligible click before a conversion.
- **Last-click:** assign credit to the last eligible click before a conversion.
- **Linear:** distribute credit equally across eligible clicks before a conversion.

Use a configurable attribution window with an initial default of **7 days**, recorded as `ATTRIBUTION_WINDOW_DAYS=7` in `.env.example`. Configuration loading is future work.

Do not add Markov, Shapley, machine learning, time-decay, or position-based attribution unless explicitly requested later. Resolve eligibility boundaries, repeat clicks, timestamp ties, and conversions without eligible clicks before implementing journey reconstruction.

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

These are guidelines, not hard constraints. No data is generated in the scaffolding milestone.

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
| `scripts/` | Local Python scripts for the planned pipeline |
| `sql/` | Future schema, analytics queries, and optimization SQL |
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

**PostgreSQL schema and local database configuration:** define tables, relationships, and constraints for the listed advertising entities in `sql/`; add minimal environment configuration and a database connection script in `scripts/`; document local database setup. Defer synthetic data generation, attribution, analytics, and dashboards to subsequent milestones. Do not begin this milestone automatically.
