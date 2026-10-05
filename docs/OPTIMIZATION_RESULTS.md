# Measured cohort-report optimization

Measured on 2026-10-05 at 09:43:14 UTC against the existing local PostgreSQL 18.6 database. These are actual PostgreSQL execution measurements, with no target percentage. Full context, SQL, and all six JSON execution plans are preserved in [optimization_measurements.json](optimization_measurements.json).

## Business query

Return acquisition-month/channel cumulative revenue and average LTV for D7/D30/D60/D90, including acquired-user counts, each horizon's eligible-user count, and the observation cutoff:

```sql
SELECT * FROM acquisition_cohort_ltv
ORDER BY acquisition_month, channel_name;
```

This existing report answers how channel cohorts monetize after acquisition. It contains acquisition ranking, revenue-time joins, observation eligibility, and aggregation; the baseline was not rewritten to manufacture inefficiency. The current report returns 15 rows across three UTC acquisition months and five channels. All D90 values are NULL because no acquired user has a full D90 observation window; those NULLs and denominators are preserved in the optimized result.

## Inspected plan and optimization

Before making changes, both source SQL and live indexes/views were inspected. Existing indexes already include `user_revenue_user_time_idx (user_id, revenue_time)`, `conversions_user_time_idx (user_id, conversion_time)`, attribution conversion/model/click uniqueness, the partial first/last-winner index, attribution campaign/model and channel/model indexes, and campaign/date spend uniqueness. No indexes were duplicated or added.

A single initial diagnostic `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` was used to select the optimization. It reported planning 1.125 ms, execution 6.180 ms, 4,561 shared buffer hits, and zero shared reads. This diagnostic is separate from, and excluded from, the six measured comparison runs below.

The baseline plan recomputes the complete report on every read:

- Bitmap index/heap scan for 898 first-click attribution rows and a hash join to 1,019 conversions.
- Sorting and `WindowAgg` to choose each user's earliest attributable conversion.
- Nested-loop revenue join using the existing `user_revenue_user_time_idx`, with 898 indexed user/time lookups and 1,547 matching receipt rows.
- A scan of 900 spend rows to determine the observation cutoff.
- Sorting and aggregation to user windows, channel joins, then sorting and aggregation to 15 cohorts.

The chosen optimization is **one materialized cohort report**, `acquisition_cohort_materialized`, populated from the existing ordinary view. Its SQL lives in `sql/optimization.sql`. This avoids repeating the acquisition/window aggregation for every read while retaining the original live view and business logic. It precomputes an analytical result rather than copying a base table. A full read of 15 stored rows needs no additional index.

The optimized query changes only the report source:

```sql
SELECT * FROM acquisition_cohort_materialized
ORDER BY acquisition_month, channel_name;
```

All three optimized plans contain a sequential scan of the 15 stored rows followed by an in-memory sort, with one shared buffer hit and no shared reads. No acquisition ranking, source-table joins, or revenue aggregation happens during those reads; that work moves to refresh.

## Method and actual timings

`scripts/benchmark_optimization.py` uses the existing database helper. The measured run first created and refreshed the materialized view, then opened one **read-only REPEATABLE READ transaction**. Exact reconciliation reads both reports before measurement, warming both sides. It then executes exactly three alternating pairs, **B1/A1/B2/A2/B3/A3**, using `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` without prepared-plan reuse. JSON retains the required ANALYZE/BUFFERS measurements and makes parsing unambiguous.

The comparison uses one connection, stable source snapshot, unchanged data, identical ordering and business question, and the server's existing planner settings. No cache was flushed, no planner features were disabled, and no favorable runs were selected. There were seven EXPLAIN ANALYZE executions during the milestone in total: one initial diagnostic plus the six comparison runs. There were no extra EXPLAIN warm-ups or repeated benchmark attempts.

Context: 1,019 conversions, 3,253 attribution rows, 1,780 revenue rows, and 900 spend rows. The acquired population is 898 users with 1,547 relevant receipts. The session timezone was `Asia/Calcutta`; acquisition months remain explicitly UTC. `work_mem` was 4 MB, JIT was on, `track_io_timing` was off, and `max_parallel_workers_per_gather` was 2. Settings are recorded for reproducibility, not changed to favor a plan.

All timings below are milliseconds reported by PostgreSQL:

| Execution order | Query | Run | Planning time | Execution time | Shared hits | Shared reads |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Baseline | 1 | 0.954 | 5.795 | 4,561 | 0 |
| 2 | Optimized | 1 | 0.049 | 0.030 | 1 | 0 |
| 3 | Baseline | 2 | 1.499 | 9.732 | 4,561 | 0 |
| 4 | Optimized | 2 | 0.055 | 0.037 | 1 | 0 |
| 5 | Baseline | 3 | 0.916 | 6.063 | 4,561 | 0 |
| 6 | Optimized | 3 | 0.203 | 0.185 | 1 | 0 |

Median baseline execution: **6.063 ms**. Median optimized execution: **0.037 ms**. Median absolute saving: **6.026 ms**. Planning medians were 0.954 ms and 0.055 ms respectively; planning is recorded separately and excluded from the requested execution-time percentage.

```text
improvement = (before_execution_ms - after_execution_ms) / before_execution_ms * 100
            = (6.063 - 0.037) / 6.063 * 100
            = 99.38974105228434768266534719%  (decimal calculation)
            = 99.389741%                      (six-decimal reporting)
```

This is the measured reduction in warm report-read execution time, not a claim about application-wide speed, source writes, or total refresh-plus-read cost.

## Exact result equivalence

`sql/optimization_checks.sql` compares every report column using `EXCEPT ALL` in both directions. It checks complete row values and multiplicity, including numeric precision, NULL horizons, eligibility counts, and the cutoff timestamp. Result ordering is identical in both report queries and both plans.

```text
Baseline rows:  15
Optimized rows: 15
Missing rows:   0
Extra rows:     0
```

Equality was checked before accepting any timings, in the same stable read-only snapshot as all six measurements. The benchmark refuses a stale/mismatched snapshot or an empty report instead of presenting an invalid speed comparison. No numeric tolerance was needed.

## Refresh cost, freshness, and limitations

The materialized view is a stored snapshot. Source receipts/spend, attribution results, or cohort-definition changes do not automatically update it. Refresh after completing any already-authorized upstream changes, before using the snapshot as the current report:

```sql
REFRESH MATERIALIZED VIEW acquisition_cohort_materialized;
```

No refresh scheduler was introduced. Ordinary refresh recomputes the full cohort report and blocks readers of this materialized view; use a quiet period. Refresh is not concurrent and no unique refresh index was added. Other ordinary views continue to read live data. Setup creates the materialized view if absent and refreshes it in one transaction; failures roll back that setup transaction. `IF NOT EXISTS` does not migrate an incompatible existing definition. A changed column contract requires explicit inspection/migration rather than treating refresh as a definition change.

Initial create/populate setup took **63.317 ms of client elapsed time**, including the DDL/refresh call. This is a separate utility measurement, not PostgreSQL query execution time or a standalone steady-state refresh estimate; it excludes connection setup and transaction commit. Refresh/setup cost and storage are excluded from the reported read-latency improvement. Freshness must be acceptable for repeated snapshot reads; the already-fast live report may remain preferable for occasional reads or immediately current data.

The dataset is small, both measured plans had zero shared reads, and PostgreSQL EXPLAIN instrumentation is included in the timings. Submillisecond optimized timings are sensitive to timer resolution and local scheduling. Baseline run 2 and optimized run 3 were slower and were retained. Three pairs demonstrate this scoped experiment, not a statistical confidence interval, cold-cache behavior, scalability result, or sustained-load guarantee. No dataset enlargement, stress/load testing, dependency installation, tests, source writes, data reload, journey/attribution rebuild, commit, or push was performed. This milestone created only the isolated materialized view and repository artifacts.

## Reproduce

With the existing environment and current source/attribution/LTV views, run from the repository root:

```powershell
# Create if absent, refresh, reconcile, and measure exactly three paired runs.
python scripts/benchmark_optimization.py --setup

# Measure an already-current snapshot without refreshing it.
python scripts/benchmark_optimization.py

# Optionally retain a NEW measurement and all six plans without overwriting this record.
python scripts/benchmark_optimization.py --setup --output docs/optimization_measurements_rerun.json
```

Without activating the virtual environment, replace `python` with `.\.venv\Scripts\python.exe`. The originally executed command was `python scripts/benchmark_optimization.py --setup --output docs/optimization_measurements.json`, using that virtual-environment interpreter. Do not run all alternatives as a benchmark loop. Timing values vary between executions; these Markdown results remain the historical measurement and are not automatically rewritten.

For SQL-client inspection, `sql/optimization_baseline.sql` and `sql/optimization_after.sql` each contain the exact raw report query and its EXPLAIN version. `sql/optimization.sql` applies creation/refresh; `sql/optimization_checks.sql` supplies reconciliation. The database role needs schema creation/materialized-view ownership, underlying view/table reads, and refresh permission (ownership or appropriate MAINTAIN privilege). The script limits connect/lock waits to five seconds and individual statements to 15 seconds.

The next recommended milestone is Metabase dashboards. No dashboard, budget allocation, deployment, cloud infrastructure, or CI/CD was implemented.
